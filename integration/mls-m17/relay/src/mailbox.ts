// Watchlink relay mailbox: one instance per opaque conversation id.
//
// Stores only ciphertext/protocol bytes (base64, opaque) and the minimum
// routing/sequencing metadata. It is sequencing input, never cryptographic
// authority: clients re-check every commit against local MLS state.
// Commit rules are the M1.4-qualified relay model (Model.swift `Relay.post`).
// Pure logic over a tiny SQL interface so it runs in a Durable Object and in
// node:sqlite tests alike. Callers hash secrets before calling in.

export interface Sql {
  run(query: string, ...params: unknown[]): Record<string, unknown>[];
}

export type Slot = "a" | "b";
export type Status = { status: "accepted" | "stale" | "ok" | "reject"; seq: number };
export type Result<T = unknown> = { code: number; body: T };

export const ENVELOPE_TTL = 72 * 3600; // undelivered ciphertext and dedup tombstones
export const CLAIM_MAX_TTL = 600; // one-time second-slot claim
export const RETIRED_TTL = 30 * 86400; // retired-conversation tombstone (no content)
export const MAX_DATA_BYTES = 64 * 1024;
export const MAX_QUEUED = 1000; // undelivered envelopes per sender
export const MAX_POSTS_PER_MINUTE = 120;
export const KINDS = ["keypackage", "welcome", "commit", "application"];

const ok = <T>(body: T): Result<T> => ({ code: 200, body });
const fail = (code: number): Result<{ error: number }> => ({ code, body: { error: code } });

export class Mailbox {
  private sql: Sql;
  private now: () => number;

  constructor(sql: Sql, now: () => number) {
    this.sql = sql;
    this.now = now;
    sql.run("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v)");
    sql.run("CREATE TABLE IF NOT EXISTS commits (base INTEGER PRIMARY KEY, id TEXT, seq INTEGER, expires INTEGER)");
    sql.run(
      "CREATE TABLE IF NOT EXISTS envelopes (seq INTEGER PRIMARY KEY, sender TEXT, kind TEXT, base INTEGER," +
        " id TEXT, data TEXT, created INTEGER, expires INTEGER)",
    );
  }

  private get(k: string): unknown {
    return this.sql.run("SELECT v FROM meta WHERE k = ?", k)[0]?.v ?? null;
  }

  private set(k: string, v: unknown): void {
    if (v === null) this.sql.run("DELETE FROM meta WHERE k = ?", k);
    else this.sql.run("INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, v);
  }

  private retired(): boolean {
    return this.get("retired") === 1;
  }

  /** Creator registers its credential verifier and the one-time claim verifier. */
  open(verifier: string, claimVerifier: string, claimExpires: number): Result {
    if (this.retired()) return fail(410);
    const a = this.get("a");
    if (a !== null) return a === verifier ? ok({}) : fail(409);
    const now = this.now();
    if (!(claimExpires > now && claimExpires <= now + CLAIM_MAX_TTL)) return fail(400);
    this.set("a", verifier);
    this.set("claim", claimVerifier);
    this.set("claimExpires", claimExpires);
    this.set("current", 0);
    this.set("nextSeq", 1);
    return ok({});
  }

  /** Second installation claims slot b with the short-lived, single-use capability. */
  claim(claimHash: string, verifier: string): Result {
    if (this.retired()) return fail(410);
    if (this.get("a") === null) return fail(404);
    const b = this.get("b");
    if (b !== null) return b === verifier ? ok({}) : fail(409);
    if (this.now() > Number(this.get("claimExpires"))) return fail(410);
    if (claimHash !== this.get("claim")) return fail(403);
    this.set("b", verifier);
    this.set("claim", null);
    this.set("claimExpires", null);
    return ok({});
  }

  /** Transport authentication only: "may access this mailbox", never peer identity. */
  slot(verifier: string): Slot | null {
    if (verifier === this.get("a")) return "a";
    if (verifier === this.get("b")) return "b";
    return null;
  }

  post(slot: Slot, kind: string, base: number | null, data: string, id: string): Result<Status | { error: number }> {
    if (!KINDS.includes(kind)) return fail(400);
    if (this.retired()) return ok({ status: "reject", seq: 0 });
    const now = this.now();
    const prior = this.sql.run("SELECT seq FROM envelopes WHERE id = ? AND sender = ?", id, slot)[0];
    if (prior) return ok({ status: kind === "commit" ? "accepted" : "ok", seq: Number(prior.seq) }); // idempotent retry
    const queued = this.sql.run(
      "SELECT COUNT(*) AS n FROM envelopes WHERE sender = ? AND data IS NOT NULL", slot)[0];
    const recent = this.sql.run(
      "SELECT COUNT(*) AS n FROM envelopes WHERE sender = ? AND created > ?", slot, now - 60)[0];
    if (Number(queued.n) >= MAX_QUEUED || Number(recent.n) >= MAX_POSTS_PER_MINUTE) return fail(429);
    const seq = Number(this.get("nextSeq"));
    if (kind === "commit") {
      if (base === null) return ok({ status: "reject", seq: 0 });
      const current = Number(this.get("current"));
      if (base < current) {
        const accepted = this.sql.run("SELECT id, seq FROM commits WHERE base = ?", base)[0];
        if (!accepted) return ok({ status: "reject", seq: 0 });
        return ok({ status: accepted.id === id ? "accepted" : "stale", seq: Number(accepted.seq) });
      }
      if (base !== current) return ok({ status: "reject", seq: 0 });
      this.sql.run("INSERT INTO commits (base, id, seq, expires) VALUES (?, ?, ?, ?)", base, id, seq, now + ENVELOPE_TTL);
      this.set("current", current + 1);
    }
    this.sql.run(
      "INSERT INTO envelopes (seq, sender, kind, base, id, data, created, expires) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      seq, slot, kind, base, id, data, now, now + ENVELOPE_TTL);
    this.set("nextSeq", seq + 1);
    return ok({ status: kind === "commit" ? "accepted" : "ok", seq });
  }

  /** Undelivered envelopes from the other slot, in relay order. */
  fetch(slot: Slot, after: number): Result {
    const rows = this.sql.run(
      "SELECT seq, kind, base, data FROM envelopes WHERE sender != ? AND seq > ? AND data IS NOT NULL" +
        " ORDER BY seq LIMIT 200", slot, after);
    return ok({ envelopes: rows.map((r) => ({ seq: Number(r.seq), kind: r.kind, base: r.base ?? null, data: r.data })) });
  }

  /** Recipient acknowledged processing through `through`: drop that ciphertext, keep a dedup tombstone. */
  ack(slot: Slot, through: number): Result {
    this.sql.run("UPDATE envelopes SET data = NULL WHERE sender != ? AND seq <= ?", slot, through);
    return ok({});
  }

  /** Explicit reset: the conversation never accepts traffic again. */
  retire(): Result {
    this.set("retired", 1);
    this.set("retiredAt", this.now());
    this.sql.run("UPDATE envelopes SET data = NULL");
    return ok({});
  }

  /** Retention sweep; returns true when nothing is left to keep. */
  sweep(): boolean {
    const now = this.now();
    this.sql.run("DELETE FROM envelopes WHERE expires < ?", now);
    this.sql.run("DELETE FROM commits WHERE expires < ? AND base < ?", now, Number(this.get("current") ?? 0) - 2);
    const abandoned = this.get("b") === null && this.get("claimExpires") !== null
      && now > Number(this.get("claimExpires"));
    const expiredTombstone = this.retired() && now > Number(this.get("retiredAt")) + RETIRED_TTL;
    if (abandoned || expiredTombstone) {
      for (const table of ["meta", "commits", "envelopes"]) this.sql.run(`DELETE FROM ${table}`);
      return true;
    }
    return this.get("a") === null;
  }
}

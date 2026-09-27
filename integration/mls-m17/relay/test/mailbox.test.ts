import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import {
  CLAIM_MAX_TTL, ENVELOPE_TTL, MAX_POSTS_PER_MINUTE, Mailbox, RETIRED_TTL, type Sql,
} from "../src/mailbox.ts";

const A = "a".repeat(64), B = "b".repeat(64), CLAIM = "c".repeat(64), OTHER = "d".repeat(64);

function mailbox() {
  const db = new DatabaseSync(":memory:");
  const sql: Sql = { run: (q, ...p) => db.prepare(q).all(...(p as never[])) as Record<string, unknown>[] };
  const clock = { now: 1_900_000_000 };
  const box = new Mailbox(sql, () => clock.now);
  return { box, sql, clock };
}

function paired() {
  const m = mailbox();
  assert.equal(m.box.open(A, CLAIM, m.clock.now + 300).code, 200);
  assert.equal(m.box.claim(CLAIM, B).code, 200);
  return m;
}

const post = (box: Mailbox, slot: "a" | "b", kind: string, base: number | null, data: string) =>
  box.post(slot, kind, base, data, `id-${data}`).body;

test("server-visible schema is exactly the documented inventory", () => {
  const { sql } = mailbox();
  const columns = (t: string) => sql.run(`PRAGMA table_info(${t})`).map((c) => c.name);
  assert.deepEqual(columns("meta"), ["k", "v"]);
  assert.deepEqual(columns("commits"), ["base", "id", "seq", "expires"]);
  assert.deepEqual(columns("envelopes"), ["seq", "sender", "kind", "base", "id", "data", "created", "expires"]);
});

test("slot b needs the one-time, short-lived claim; the conversation id alone is not enough", () => {
  const { box, clock } = mailbox();
  assert.equal(box.claim(CLAIM, B).code, 404, "nothing to claim before open");
  assert.equal(box.open(A, CLAIM, clock.now + CLAIM_MAX_TTL + 1).code, 400, "claim lifetime bounded");
  assert.equal(box.open(A, CLAIM, clock.now + 300).code, 200);
  assert.equal(box.open(A, CLAIM, clock.now + 300).code, 200, "idempotent retry by the creator");
  assert.equal(box.open(OTHER, CLAIM, clock.now + 300).code, 409, "slot a cannot be taken over");
  assert.equal(box.claim(OTHER, B).code, 403, "wrong capability");
  assert.equal(box.claim(CLAIM, B).code, 200);
  assert.equal(box.claim(CLAIM, B).code, 200, "idempotent retry by the claimant");
  assert.equal(box.claim(CLAIM, OTHER).code, 409, "single use: second claimant refused");
  assert.equal(box.slot(A), "a");
  assert.equal(box.slot(B), "b");
  assert.equal(box.slot(OTHER), null);
});

test("claim capability expires", () => {
  const { box, clock } = mailbox();
  box.open(A, CLAIM, clock.now + 300);
  clock.now += 301;
  assert.equal(box.claim(CLAIM, B).code, 410);
});

test("qualified commit sequencing: one commit per base; stale/duplicate/lying bases", () => {
  const { box } = paired();
  assert.deepEqual(post(box, "a", "commit", 0, "x"), { status: "accepted", seq: 1 });
  assert.deepEqual(post(box, "a", "commit", 0, "x"), { status: "accepted", seq: 1 }, "idempotent retransmission");
  assert.deepEqual(post(box, "b", "commit", 0, "y"), { status: "stale", seq: 1 });
  assert.deepEqual(post(box, "b", "commit", 5, "z"), { status: "reject", seq: 0 }, "future base");
  assert.deepEqual(post(box, "b", "commit", null, "z"), { status: "reject", seq: 0 });
  assert.deepEqual(post(box, "b", "commit", 1, "w"), { status: "accepted", seq: 2 });
  assert.equal(box.post("a", "text", null, "q", "i").code, 400, "unknown kind");
});

test("fetch returns only the peer's undelivered ciphertext in order; ack deletes it", () => {
  const { box } = paired();
  post(box, "a", "application", 1, "m1");
  post(box, "b", "application", 1, "own");
  post(box, "a", "application", 1, "m2");
  const fetched = box.fetch("b", 0).body as { envelopes: { seq: number; data: string }[] };
  assert.deepEqual(fetched.envelopes.map((e) => [e.seq, e.data]), [[1, "m1"], [3, "m2"]]);
  assert.deepEqual((box.fetch("b", 1).body as typeof fetched).envelopes.map((e) => e.seq), [3]);
  box.ack("b", 1);
  assert.deepEqual((box.fetch("b", 0).body as typeof fetched).envelopes.map((e) => e.seq), [3]);
  assert.deepEqual(post(box, "a", "application", 1, "m1"), { status: "ok", seq: 1 }, "dedup tombstone after ack");
  assert.equal((box.fetch("b", 0).body as typeof fetched).envelopes.length, 1, "no resurrection");
});

test("retire: no new traffic, content dropped, cannot be reopened", () => {
  const { box, clock } = paired();
  post(box, "a", "application", 1, "m1");
  box.retire();
  assert.deepEqual(post(box, "b", "application", 1, "late"), { status: "reject", seq: 0 });
  assert.equal((box.fetch("b", 0).body as { envelopes: unknown[] }).envelopes.length, 0);
  assert.equal(box.open(OTHER, CLAIM, clock.now + 300).code, 410, "relay cannot revive a retired conversation");
  assert.equal(box.sweep(), false, "tombstone kept");
  clock.now += RETIRED_TTL + 1;
  assert.equal(box.sweep(), true, "tombstone expires");
});

test("retention: ciphertext and tombstones expire after 72h; abandoned pairings vanish", () => {
  const { box, sql, clock } = paired();
  post(box, "a", "application", 1, "m1");
  clock.now += ENVELOPE_TTL + 1;
  box.sweep();
  assert.equal(sql.run("SELECT COUNT(*) AS n FROM envelopes")[0].n, 0);

  const abandoned = mailbox();
  abandoned.box.open(A, CLAIM, abandoned.clock.now + 300);
  abandoned.clock.now += 301;
  assert.equal(abandoned.box.sweep(), true);
  assert.equal(abandoned.sql.run("SELECT COUNT(*) AS n FROM meta")[0].n, 0);
});

test("per-sender rate limit", () => {
  const { box } = paired();
  for (let i = 0; i < MAX_POSTS_PER_MINUTE; i++) post(box, "a", "application", 1, `r${i}`);
  assert.equal(box.post("a", "application", 1, "over", "id-over").code, 429);
  assert.equal(box.post("b", "application", 1, "peer", "id-peer").code, 200, "other slot unaffected");
});

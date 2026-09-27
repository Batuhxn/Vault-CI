// Watchlink relay Worker: HTTPS front door + one SQLite-backed Durable Object
// per opaque conversation id. No logging: nothing here emits log output.

import { DurableObject } from "cloudflare:workers";
import { MAX_DATA_BYTES, Mailbox, type Result, type Slot } from "./mailbox.ts";

interface Env {
  MAILBOX: DurableObjectNamespace<MailboxObject>;
}

const MAX_BODY_BYTES = 100 * 1024;
const CID = /^[A-Za-z0-9_-]{22}$/; // base64url of 16 random bytes
const ROUTE = /^\/v1\/c\/([^/]+)\/(open|claim|envelopes|ack|retire)$/;

export class MailboxObject extends DurableObject<Env> {
  private mailbox: Mailbox;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const sql = { run: (q: string, ...p: unknown[]) => ctx.storage.sql.exec(q, ...p).toArray() };
    this.mailbox = new Mailbox(sql, () => Math.floor(Date.now() / 1000));
  }

  /** One atomic, strongly consistent operation. `verifier` is already a hash. */
  async call(op: string, verifier: string | null, args: Record<string, unknown>): Promise<Result> {
    const result = this.ctx.storage.transactionSync((): Result => {
      if (op === "open") return this.mailbox.open(verifier!, String(args.claimVerifier), Number(args.claimExpires));
      if (op === "claim") return this.mailbox.claim(String(args.claimHash), verifier!);
      const slot: Slot | null = verifier === null ? null : this.mailbox.slot(verifier);
      if (slot === null) return { code: 401, body: { error: 401 } };
      if (op === "post") {
        return this.mailbox.post(slot, String(args.kind), args.base as number | null, String(args.data), String(args.id));
      }
      if (op === "fetch") return this.mailbox.fetch(slot, Number(args.after));
      if (op === "ack") return this.mailbox.ack(slot, Number(args.through));
      if (op === "retire") return this.mailbox.retire();
      return { code: 404, body: { error: 404 } };
    });
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now() + 3600_000);
    return result;
  }

  async alarm(): Promise<void> {
    const empty = this.ctx.storage.transactionSync(() => this.mailbox.sweep());
    if (empty) await this.ctx.storage.deleteAll();
    else await this.ctx.storage.setAlarm(Date.now() + 3600_000);
  }
}

function decode(base64: string): Uint8Array<ArrayBuffer> | null {
  try {
    return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

async function sha256Hex(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

const json = (code: number, body: unknown) =>
  new Response(JSON.stringify(body), { status: code, headers: { "content-type": "application/json" } });

async function credentialHash(request: Request): Promise<string | null> {
  const match = /^Bearer ([A-Za-z0-9+/=]{40,64})$/.exec(request.headers.get("authorization") ?? "");
  const token = match ? decode(match[1]) : null;
  return token && token.length === 32 ? sha256Hex(token) : null;
}

const isHash = (v: unknown) => typeof v === "string" && /^[0-9a-f]{64}$/.test(v);

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = ROUTE.exec(url.pathname);
    if (!route || !CID.test(route[1])) return json(404, { error: 404 });
    const [, cid, op] = route;
    if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) return json(413, { error: 413 });
    let body: Record<string, unknown> = {};
    if (request.method === "POST") {
      const text = await request.text();
      if (text.length > MAX_BODY_BYTES) return json(413, { error: 413 });
      try {
        body = text ? JSON.parse(text) : {};
      } catch {
        return json(400, { error: 400 });
      }
    } else if (!(request.method === "GET" && op === "envelopes")) {
      return json(405, { error: 405 });
    }

    const stub = env.MAILBOX.get(env.MAILBOX.idFromName(cid));
    let result: Result;
    if (op === "open") {
      const token = decode(String(body.credential ?? ""));
      if (!token || token.length !== 32 || !isHash(body.claimVerifier)) return json(400, { error: 400 });
      result = await stub.call("open", await sha256Hex(token), {
        claimVerifier: body.claimVerifier,
        claimExpires: body.claimExpires,
      });
    } else if (op === "claim") {
      const token = decode(String(body.credential ?? ""));
      const claim = decode(String(body.claim ?? ""));
      if (!token || token.length !== 32 || !claim || claim.length !== 32) return json(400, { error: 400 });
      result = await stub.call("claim", await sha256Hex(token), { claimHash: await sha256Hex(claim) });
    } else {
      const verifier = await credentialHash(request);
      if (verifier === null) return json(401, { error: 401 });
      if (op === "envelopes" && request.method === "GET") {
        const after = Number(url.searchParams.get("after") ?? "0");
        if (!Number.isSafeInteger(after) || after < 0) return json(400, { error: 400 });
        result = await stub.call("fetch", verifier, { after });
      } else if (op === "envelopes") {
        const data = decode(String(body.data ?? ""));
        const base = body.base ?? null;
        if (!data || data.length === 0 || data.length > MAX_DATA_BYTES) return json(400, { error: 400 });
        if (base !== null && !(Number.isSafeInteger(base) && (base as number) >= 0)) return json(400, { error: 400 });
        result = await stub.call("post", verifier, { kind: body.kind, base, data: body.data, id: await sha256Hex(data) });
      } else if (op === "ack") {
        if (!(Number.isSafeInteger(body.through) && (body.through as number) >= 0)) return json(400, { error: 400 });
        result = await stub.call("ack", verifier, { through: body.through });
      } else {
        result = await stub.call("retire", verifier, {});
      }
    }
    return json(result.code, result.body);
  },
} satisfies ExportedHandler<Env>;

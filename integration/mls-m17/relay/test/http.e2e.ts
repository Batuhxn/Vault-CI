// End-to-end HTTP checks against a running relay: RELAY_URL=http://127.0.0.1:8787.
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { test } from "node:test";

const RELAY = process.env.RELAY_URL;
const b64 = (b: Buffer) => b.toString("base64");
const cid = () => randomBytes(16).toString("base64url");

async function call(path: string, init: { method?: string; token?: Buffer; body?: unknown } = {}) {
  const response = await fetch(`${RELAY}/v1/c/${path}`, {
    method: init.method ?? (init.body === undefined ? "GET" : "POST"),
    headers: {
      "content-type": "application/json",
      ...(init.token ? { authorization: `Bearer ${b64(init.token)}` } : {}),
    },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  return { code: response.status, body: await response.json() as Record<string, any> };
}

async function pair() {
  const id = cid(), a = randomBytes(32), b = randomBytes(32), claim = randomBytes(32);
  const claimVerifier = createHash("sha256").update(claim).digest("hex");
  const expires = Math.floor(Date.now() / 1000) + 300;
  assert.equal((await call(`${id}/open`, { body: { credential: b64(a), claimVerifier, claimExpires: expires } })).code, 200);
  assert.equal((await call(`${id}/claim`, { body: { credential: b64(b), claim: b64(randomBytes(32)) } })).code, 403);
  assert.equal((await call(`${id}/claim`, { body: { credential: b64(b), claim: b64(claim) } })).code, 200);
  return { id, a, b };
}

test("relay HTTP contract", { skip: !RELAY }, async () => {
  const { id, a, b } = await pair();
  assert.equal((await call(`${id}/envelopes`, { token: randomBytes(32) })).code, 401, "unknown credential");
  assert.equal((await call(`not-a-conversation/envelopes`, { token: a })).code, 404);

  // The relay only ever receives opaque bytes; a well-behaved client never sends
  // plaintext, and here we prove the relay representation carries only what it was given.
  const ciphertext = randomBytes(200);
  const posted = await call(`${id}/envelopes`, { token: a, body: { kind: "application", base: 1, data: b64(ciphertext) } });
  assert.deepEqual(posted.body, { status: "ok", seq: 1 });
  assert.deepEqual((await call(`${id}/envelopes`, { token: a, body: { kind: "application", base: 1, data: b64(ciphertext) } })).body,
    { status: "ok", seq: 1 }, "dropped-ACK retry is idempotent");
  const fetched = await call(`${id}/envelopes?after=0`, { token: b });
  assert.deepEqual(fetched.body.envelopes, [{ seq: 1, kind: "application", base: 1, data: b64(ciphertext) }]);
  assert.deepEqual(Object.keys(fetched.body.envelopes[0]).sort(), ["base", "data", "kind", "seq"], "minimal fields");
  assert.equal((await call(`${id}/envelopes?after=0`, { token: a })).body.envelopes.length, 0, "own items not echoed");

  assert.equal((await call(`${id}/ack`, { token: b, body: { through: 1 } })).code, 200);
  assert.equal((await call(`${id}/envelopes?after=0`, { token: b })).body.envelopes.length, 0, "deleted after ack");

  assert.deepEqual((await call(`${id}/envelopes`, { token: a, body: { kind: "commit", base: 0, data: b64(randomBytes(64)) } })).body,
    { status: "accepted", seq: 2 });
  assert.equal((await call(`${id}/envelopes`, { token: b, body: { kind: "commit", base: 0, data: b64(randomBytes(64)) } })).body.status,
    "stale");
  assert.equal((await call(`${id}/envelopes`, { token: a, body: { kind: "application", base: 1, data: "" } })).code, 400);
  assert.equal((await call(`${id}/envelopes`, { token: a, body: { kind: "application", base: 1, data: b64(randomBytes(70_000)) } })).code, 400);

  assert.equal((await call(`${id}/retire`, { token: a, body: {} })).code, 200);
  assert.equal((await call(`${id}/envelopes`, { token: b, body: { kind: "application", base: 1, data: b64(randomBytes(8)) } })).body.status,
    "reject");
  const reopen = await call(`${id}/open`, {
    body: { credential: b64(randomBytes(32)), claimVerifier: "0".repeat(64), claimExpires: Math.floor(Date.now() / 1000) + 60 },
  });
  assert.equal(reopen.code, 410, "retired conversation cannot be revived");
});

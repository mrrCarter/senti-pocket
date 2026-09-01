import { test } from "node:test";
import assert from "node:assert/strict";

import { buildRingRequest, callMe, parseArgs, main } from "./call-me.mjs";

// ── fake fetch: queue of responses, captures request bodies ───────────────────
function fakeFetch(responses) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const r = responses.shift();
    if (!r) throw new Error("fakeFetch: no more responses queued");
    if (r.throw) throw new Error(r.throw);
    return {
      status: r.status,
      headers: { get: (k) => (r.headers || {})[String(k).toLowerCase()] ?? null },
      json: async () => r.json ?? {},
    };
  };
  impl.calls = calls;
  return impl;
}

const noSleep = () => Promise.resolve();

// ── buildRingRequest ──────────────────────────────────────────────────────────
test("buildRingRequest: rejects missing session and message", () => {
  assert.throws(() => buildRingRequest({ message: "hi" }), /session is required/);
  assert.throws(() => buildRingRequest({ session: "s" }), /message is required/);
});

test("buildRingRequest: rejects an over-long message and a bad kind", () => {
  const long = "x".repeat(4097);
  assert.throws(() => buildRingRequest({ session: "s", message: long }), /exceeds 4096/);
  assert.throws(() => buildRingRequest({ session: "s", message: "hi", kind: "bogus" }), /kind must be one of/);
});

test("buildRingRequest: pickOption is atomic with its options", () => {
  assert.throws(() => buildRingRequest({ session: "s", message: "q", kind: "pickOption" }), /requires at least one --option/);
  const body = buildRingRequest({ session: "s", message: "q", kind: "pickOption", options: ["a", "b"] });
  assert.deepEqual(body.options, ["a", "b"]);
});

test("buildRingRequest: default kind, caller is display, idempotencyKey auto-set", () => {
  const body = buildRingRequest({ session: "s", message: "need you", caller: "claude-forge" });
  assert.equal(body.kind, "decisionYours");
  assert.equal(body.sessionId, "s");
  assert.equal(body.callerName, "claude-forge");
  assert.ok(body.idempotencyKey && body.idempotencyKey.startsWith("cli-"));
  assert.equal("options" in body, false); // non-pickOption carries no options
});

// ── callMe transport ──────────────────────────────────────────────────────────
test("callMe: 200 returns dialId and ok", async () => {
  const fetch = fakeFetch([{ status: 200, json: { dialId: "dial_abc", dispatched: true } }]);
  const res = await callMe(
    { gateway: "https://gw/", token: "t", session: "s", message: "hi" },
    { fetch, sleep: noSleep },
  );
  assert.equal(res.ok, true);
  assert.equal(res.dialId, "dial_abc");
  assert.equal(res.attempts, 1);
  assert.equal(fetch.calls[0].url, "https://gw/dial/ring-owner");
  assert.equal(fetch.calls[0].init.headers.authorization, "Bearer t");
});

test("callMe: missing gateway or token fails without a request", async () => {
  const fetch = fakeFetch([]);
  const noGw = await callMe({ token: "t", session: "s", message: "hi" }, { fetch, sleep: noSleep });
  assert.equal(noGw.ok, false);
  const noTok = await callMe({ gateway: "https://gw", session: "s", message: "hi" }, { fetch, sleep: noSleep });
  assert.equal(noTok.ok, false);
  assert.equal(fetch.calls.length, 0);
});

test("callMe: 429 honors Retry-After, bounded retries, then fails — same idempotencyKey throughout", async () => {
  const slept = [];
  const fetch = fakeFetch([
    { status: 429, headers: { "retry-after": "1" }, json: { error: "rate_limited" } },
    { status: 429, headers: { "retry-after": "1" }, json: { error: "rate_limited" } },
    { status: 429, json: { error: "rate_limited" } },
    { status: 429, json: { error: "rate_limited" } },
  ]);
  const res = await callMe(
    { gateway: "https://gw", token: "t", session: "s", message: "hi", baseBackoffMs: 10 },
    { fetch, sleep: (ms) => { slept.push(ms); return Promise.resolve(); } },
  );
  assert.equal(res.ok, false);
  assert.match(res.error, /429/);
  assert.equal(res.attempts, 4); // 1 + 3 retries
  assert.equal(fetch.calls.length, 4);
  assert.equal(slept[0], 1000); // honored Retry-After: 1s -> 1000ms
  const keys = new Set(fetch.calls.map((c) => c.body.idempotencyKey));
  assert.equal(keys.size, 1, "retries must reuse one idempotency key (exactly-once)");
});

test("callMe: 503 retries then succeeds", async () => {
  const fetch = fakeFetch([
    { status: 503, json: { error: "retryable" } },
    { status: 200, json: { dialId: "dial_z" } },
  ]);
  const res = await callMe(
    { gateway: "https://gw", token: "t", session: "s", message: "hi", baseBackoffMs: 1 },
    { fetch, sleep: noSleep },
  );
  assert.equal(res.ok, true);
  assert.equal(res.dialId, "dial_z");
  assert.equal(res.attempts, 2);
});

test("callMe: a non-retryable 4xx surfaces immediately, no retry", async () => {
  const fetch = fakeFetch([{ status: 403, json: { error: "forbidden", reason: "nonmember" } }]);
  const res = await callMe(
    { gateway: "https://gw", token: "t", session: "s", message: "hi" },
    { fetch, sleep: noSleep },
  );
  assert.equal(res.ok, false);
  assert.equal(res.status, 403);
  assert.equal(res.reason, "nonmember");
  assert.equal(fetch.calls.length, 1);
});

test("callMe: network error retries then gives up", async () => {
  const fetch = fakeFetch([{ throw: "ECONNRESET" }, { throw: "ECONNRESET" }, { throw: "ECONNRESET" }, { throw: "ECONNRESET" }]);
  const res = await callMe(
    { gateway: "https://gw", token: "t", session: "s", message: "hi", baseBackoffMs: 1 },
    { fetch, sleep: noSleep },
  );
  assert.equal(res.ok, false);
  assert.match(res.error, /network error/);
  assert.equal(res.attempts, 4);
});

// ── CLI arg parsing + main ────────────────────────────────────────────────────
test("parseArgs: flags, repeatable --option, unknown flag throws", () => {
  const a = parseArgs(["--session", "s", "--message", "m", "--kind", "pickOption", "--option", "a", "--option", "b", "--json"]);
  assert.equal(a.session, "s");
  assert.equal(a.kind, "pickOption");
  assert.deepEqual(a.options, ["a", "b"]);
  assert.equal(a.json, true);
  assert.throws(() => parseArgs(["--nope"]), /unknown flag/);
});

test("main: --dry-run prints the request and returns 0 without sending", async () => {
  const lines = [];
  const io = { log: (s) => lines.push(s), error: (s) => lines.push("ERR:" + s) };
  const code = await main(
    ["--session", "s", "--message", "need you", "--dry-run"],
    { SENTI_GATEWAY_URL: "https://gw", SENTI_DIAL_TOKEN: "t" },
    io,
  );
  assert.equal(code, 0);
  const printed = JSON.parse(lines.join("\n"));
  assert.equal(printed.url, "https://gw/dial/ring-owner");
  assert.equal(printed.body.sessionId, "s");
  assert.equal(printed.body.kind, "decisionYours");
});

test("main: bad input returns exit code 2", async () => {
  const io = { log() {}, error() {} };
  const code = await main(["--message", "no session"], { SENTI_GATEWAY_URL: "https://gw", SENTI_DIAL_TOKEN: "t" }, io);
  assert.equal(code, 2);
});

test("main: --help returns 0", async () => {
  const io = { log() {}, error() {} };
  const code = await main(["--help"], {}, io);
  assert.equal(code, 0);
});

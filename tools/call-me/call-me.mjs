#!/usr/bin/env node
// call-me — ring the session owner's phone from ANY shell (microVM, vscode, CI, MCP).
//
// Thin, zero-dependency client over the gateway's CALL-ME transport
// (`POST {GATEWAY}/dial/ring-owner`), per docs/CALL_ME_AND_VOICE_CONTRACT.md (v0.2).
// Owns NO secrets beyond a scoped, short-TTL dial token injected as env — provider
// keys never enter a box (standing rule); the voice-provider key stays server-side.
//
// Security the SERVER enforces (this client cannot bypass): the human target and the
// caller identity are both derived from the token, never the body (confused-deputy-safe,
// both target and source). This client's job is to describe the need and back off politely.
//
// Usage:
//   SENTI_GATEWAY_URL=https://gw  SENTI_DIAL_TOKEN=… \
//   node call-me.mjs --session <id> --message "<need>" [--kind decisionYours] \
//        [--option A --option B] [--caller <display>] [--priority high] [--json] [--dry-run]
//
// Wiring as `sl call-me`: this file is import-safe — `callMe()` is the reusable core an
// `sl` subcommand or an MCP tool (`call_me`) wraps; `main()` runs only on direct invocation.

export const DIAL_KINDS = Object.freeze(["info", "checkpointReady", "decisionYours", "pickOption", "go"]);
const WRITE_KINDS = new Set(["decisionYours", "pickOption", "go"]);
const MESSAGE_MAX_BYTES = 4096;
const DEFAULT_MAX_RETRIES = 3;
const RETRYABLE_STATUS = new Set([429, 503]);

function randomIdempotencyKey() {
  // Stable across THIS invocation's retries (exactly-once for one ring), unique across
  // invocations (two intentional runs = two rings). No crypto dep needed.
  return "cli-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 12);
}

function byteLength(text) {
  return typeof Buffer !== "undefined"
    ? Buffer.byteLength(text, "utf8")
    : new TextEncoder().encode(text).length;
}

/**
 * Validate + normalize a call-me request. Throws Error with a stable `.code` on bad input
 * so both the CLI and an MCP wrapper get the same client-side guardrails the server enforces.
 */
export function buildRingRequest({ session, message, kind = "decisionYours", options = [], caller, priority, context, checkpointId, idempotencyKey }) {
  if (!session || typeof session !== "string" || !session.trim()) {
    throw Object.assign(new Error("--session is required"), { code: "session_required" });
  }
  if (!message || typeof message !== "string" || !message.trim()) {
    throw Object.assign(new Error("--message is required"), { code: "message_required" });
  }
  if (byteLength(message) > MESSAGE_MAX_BYTES) {
    throw Object.assign(new Error(`--message exceeds ${MESSAGE_MAX_BYTES} bytes`), { code: "message_too_long" });
  }
  if (!DIAL_KINDS.includes(kind)) {
    throw Object.assign(new Error(`--kind must be one of: ${DIAL_KINDS.join(", ")}`), { code: "bad_kind" });
  }
  if (kind === "pickOption" && (!Array.isArray(options) || options.length === 0)) {
    throw Object.assign(new Error("--kind pickOption requires at least one --option (atomic with its options)"), { code: "options_required" });
  }
  const body = { sessionId: session, kind, message };
  if (kind === "pickOption") body.options = options;
  // callerName is DISPLAY-SECONDARY only — the server stamps the real caller identity from
  // the token subject (AMEND-2). We still pass a display hint when given.
  if (caller) body.callerName = caller;
  if (priority) body.priority = priority;
  if (context) body.context = context;
  if (checkpointId) body.checkpointId = checkpointId;
  body.idempotencyKey = idempotencyKey || randomIdempotencyKey();
  return body;
}

function parseRetryAfter(headerValue, nowMs) {
  if (!headerValue) return null;
  const seconds = Number(headerValue);
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000);
  const dateMs = Date.parse(headerValue);
  if (Number.isFinite(dateMs)) return Math.max(0, dateMs - (nowMs ?? Date.now()));
  return null;
}

/**
 * Ring the owner. Returns { ok, status, dialId?, dispatched?, error?, attempts }.
 * Never throws on a gateway/network error — reports it. Throws only on bad INPUT
 * (via buildRingRequest) so callers can distinguish a usage bug from a transport failure.
 *
 * Backoff (AMEND-1): honors `Retry-After` on 429, bounded retries on 429/503/network,
 * then gives up with a non-zero-mapped result. Never busy-loops the doorbell.
 */
export async function callMe(opts, deps = {}) {
  const fetchImpl = deps.fetch || globalThis.fetch;
  const sleep = deps.sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const now = deps.now || (() => Date.now());
  if (typeof fetchImpl !== "function") {
    return { ok: false, status: 0, error: "no fetch available (need Node 18+ or a deps.fetch)", attempts: 0 };
  }
  const gateway = (opts.gateway || "").replace(/\/+$/, "");
  if (!gateway) return { ok: false, status: 0, error: "gateway URL required (SENTI_GATEWAY_URL or --gateway)", attempts: 0 };
  if (!opts.token) return { ok: false, status: 0, error: "dial token required (SENTI_DIAL_TOKEN)", attempts: 0 };

  const body = buildRingRequest(opts); // throws on bad input
  const url = `${gateway}/dial/ring-owner`;
  const maxRetries = Number.isInteger(opts.maxRetries) ? opts.maxRetries : DEFAULT_MAX_RETRIES;
  const baseBackoffMs = opts.baseBackoffMs ?? 500;

  let attempt = 0;
  let lastError = null;
  while (attempt <= maxRetries) {
    attempt += 1;
    let res;
    try {
      res = await fetchImpl(url, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${opts.token}` },
        body: JSON.stringify(body),
      });
    } catch (networkErr) {
      lastError = `network error: ${networkErr?.message || networkErr}`;
      if (attempt > maxRetries) break;
      await sleep(baseBackoffMs * 2 ** (attempt - 1));
      continue; // retry with the SAME idempotencyKey
    }

    const status = res.status;
    let parsed = null;
    try { parsed = await res.json(); } catch { parsed = null; }

    if (status === 200) {
      return { ok: true, status, dialId: parsed?.dialId ?? null, dispatched: parsed?.dispatched ?? true, attempts: attempt };
    }
    if (RETRYABLE_STATUS.has(status)) {
      lastError = `${status} ${parsed?.error || (status === 429 ? "rate_limited" : "retryable")}`;
      if (attempt > maxRetries) break;
      const retryAfterMs = status === 429
        ? parseRetryAfter(res.headers?.get?.("retry-after"), now())
        : null;
      const backoff = retryAfterMs ?? baseBackoffMs * 2 ** (attempt - 1);
      await sleep(backoff);
      continue;
    }
    // Non-retryable gateway error (400/401/403/413/501/…): surface and stop.
    return { ok: false, status, error: parsed?.error || `gateway returned ${status}`, reason: parsed?.reason, attempts: attempt };
  }
  return { ok: false, status: 0, error: lastError || "exhausted retries", attempts: attempt };
}

// ── CLI front-end ───────────────────────────────────────────────────────────────
export function parseArgs(argv) {
  const out = { options: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => argv[++i];
    switch (arg) {
      case "--session": out.session = next(); break;
      case "--message": out.message = next(); break;
      case "--kind": out.kind = next(); break;
      case "--option": out.options.push(next()); break;
      case "--caller": out.caller = next(); break;
      case "--priority": out.priority = next(); break;
      case "--context": out.context = next(); break;
      case "--checkpoint": out.checkpointId = next(); break;
      case "--idempotency-key": out.idempotencyKey = next(); break;
      case "--gateway": out.gateway = next(); break;
      case "--json": out.json = true; break;
      case "--dry-run": out.dryRun = true; break;
      case "-h": case "--help": out.help = true; break;
      default:
        if (arg?.startsWith("--")) throw Object.assign(new Error(`unknown flag: ${arg}`), { code: "bad_flag" });
    }
  }
  return out;
}

const HELP = `call-me — ring the session owner's phone from any shell.

  node call-me.mjs --session <id> --message "<need>" [options]

Required env: SENTI_GATEWAY_URL, SENTI_DIAL_TOKEN (scoped short-TTL pocket:dial token).

Options:
  --kind <k>        info | checkpointReady | decisionYours | pickOption | go   (default decisionYours)
  --option <text>   an option (repeatable); required when --kind pickOption
  --caller <name>   display hint only; server stamps the real caller identity from the token
  --priority <p>    normal | high
  --context <text>  ancillary context (not part of ring identity/idempotency)
  --idempotency-key <k>   override; default is a per-invocation stable key
  --gateway <url>   override SENTI_GATEWAY_URL
  --json            print the raw gateway response
  --dry-run         print the request that would be sent, do not send
`;

export async function main(argv, env = process.env, io = console) {
  let args;
  try { args = parseArgs(argv); } catch (e) { io.error(e.message); return 2; }
  if (args.help) { io.log(HELP); return 0; }

  const opts = {
    gateway: args.gateway || env.SENTI_GATEWAY_URL,
    token: env.SENTI_DIAL_TOKEN,
    session: args.session,
    message: args.message,
    kind: args.kind || "decisionYours",
    options: args.options,
    caller: args.caller,
    priority: args.priority,
    context: args.context,
    checkpointId: args.checkpointId,
    idempotencyKey: args.idempotencyKey,
  };

  if (args.dryRun) {
    try {
      const body = buildRingRequest(opts);
      io.log(JSON.stringify({ url: `${(opts.gateway || "").replace(/\/+$/, "")}/dial/ring-owner`, body }, null, 2));
      return 0;
    } catch (e) { io.error(e.message); return 2; }
  }

  let result;
  try {
    result = await callMe(opts);
  } catch (e) {
    io.error(`call-me: ${e.message}`); // bad input
    return 2;
  }
  if (args.json) io.log(JSON.stringify(result));
  if (result.ok) {
    if (!args.json) io.log(`ringing owner — dialId=${result.dialId} (attempt ${result.attempts})`);
    return 0;
  }
  if (!args.json) io.error(`call-me failed: ${result.error}${result.status ? ` [HTTP ${result.status}]` : ""}`);
  return 1;
}

// Run only when invoked directly, not when imported (import-safe for sl / MCP wrappers).
const invokedDirectly = (() => {
  try { return import.meta.url === `file://${process.argv[1]}` || import.meta.url.endsWith(process.argv[1]?.replace(/\\/g, "/")); }
  catch { return false; }
})();
if (invokedDirectly) {
  main(process.argv.slice(2)).then((code) => process.exit(code)).catch((e) => { console.error(e); process.exit(1); });
}

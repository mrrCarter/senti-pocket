// dial-signal-store.mjs — the dispatch-time store for a LEAN (fetch=true) ring's authoritative full signal. Relay lane.
//
// WHY (dialPayloadV1 spec v0.6, seam d): a LEAN ring (the payload exceeded the 5120-byte PushKit budget) ships only the
// CORE (v/id/kind/priority/callerName/who/sessionId/checkpointId?/fetch/ts) and sheds ALL governed content
// (message/options/context/evidenceSeqs). The phone, on `fetch:true`, hydrates the full signal via the AUTHENTICATED
// `GET /dial?id=` (PR-B2) — which reads back the signal THIS store held at dispatch, keyed by the ring's dialId. So a
// long/rich ring still delivers instantly (a doorbell) and the full question/options/evidence load on pickup, post-auth.
//
// EXPIRY IS LOGICAL, NOT DELETION-DEPENDENT: DynamoDB TTL deletion lags (can be hours), so get() checks `expiresAtSec`
// logically on read — same discipline as the lock roster. The top-level `ttl` (via putIfAbsent's ttlEpochSec) is only the
// eventual-cleanup signal, never the correctness gate. After TTL: get() -> undefined -> the endpoint returns 410 Gone ->
// the phone shows honest unavailable/retry, NEVER a fabricated hydrate. TTL 900s covers the ring lifetime + hydrate retries.
//
// This module holds NO auth: membership+session binding is enforced at the GET /dial?id= endpoint (PR-B2) BEFORE it calls
// get(). It is a pure store wrapper over the gateway's existing { get, put[, putIfAbsent] } store — zero new infra.

export const DIAL_SIGNAL_TTL_SECONDS = 900;   // ring lifetime + a couple of hydrate retries
const MAX_SIGNAL_BYTES = 8192;                 // the signal arrives bounded from the mapper; this is a defensive fail-closed cap

/** Injection-safe key: dialId is length-prefixed so ("a","b:c")- vs ("a:b","c")-style boundaries can never collide. */
const sigKey = (dialId) => `dial:sig:${String(dialId).length}:${dialId}`;

/**
 * @param {{ store: {get:Function, put:Function, putIfAbsent?:Function}, now?: ()=>number, ttlSeconds?: number }} cfg
 */
export function createDialSignalStore({ store, now = () => Date.now(), ttlSeconds = DIAL_SIGNAL_TTL_SECONDS } = {}) {
  if (!store || typeof store.get !== 'function' || typeof store.put !== 'function') {
    throw new Error('createDialSignalStore requires a { get, put } store');
  }
  const clock = typeof now === 'function' ? now : () => Date.now();
  const ttl = Number.isInteger(ttlSeconds) && ttlSeconds > 0 ? ttlSeconds : DIAL_SIGNAL_TTL_SECONDS;

  return {
    ttlSeconds: ttl,

    /**
     * Store the authoritative full signal at dispatch, keyed by dialId, with a logical + DynamoDB TTL.
     * putIfAbsent (when available) gives DynamoDB cleanup (ttlEpochSec) AND idempotency — a re-dispatch of the same
     * dialId keeps the FIRST-stored signal (returns stored:false); either way the signal is retrievable for hydration.
     * @returns {Promise<{ stored: boolean, expiresAtSec: number }>}
     */
    async put(dialId, signal) {
      if (typeof dialId !== 'string' || dialId.trim().length === 0) throw new Error('dial signal store: dialId required');
      if (signal === null || typeof signal !== 'object') throw new Error('dial signal store: signal object required');
      const bytes = Buffer.byteLength(JSON.stringify(signal), 'utf8');
      if (bytes > MAX_SIGNAL_BYTES) throw new Error(`dial signal store: signal exceeds ${MAX_SIGNAL_BYTES} bytes`);
      const expiresAtSec = Math.floor(clock() / 1000) + ttl;
      const record = { signal, expiresAtSec };
      let stored = true;
      if (typeof store.putIfAbsent === 'function') stored = (await store.putIfAbsent(sigKey(dialId), record, { ttlEpochSec: expiresAtSec })) !== false;
      else await store.put(sigKey(dialId), record);
      return { stored, expiresAtSec };
    },

    /**
     * Read the stored signal for a dialId, honoring LOGICAL expiry. Absent/expired -> undefined (endpoint -> 410 -> honest
     * unavailable). Never returns a partial or fabricated signal.
     */
    async get(dialId) {
      if (typeof dialId !== 'string' || dialId.trim().length === 0) return undefined;
      const rec = await store.get(sigKey(dialId));
      if (!rec || typeof rec !== 'object' || !Number.isFinite(rec.expiresAtSec)) return undefined;
      if (Math.floor(clock() / 1000) > rec.expiresAtSec) return undefined; // logically expired (DynamoDB deletion lags)
      return rec.signal;
    },
  };
}

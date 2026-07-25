// dial-signal-store.mjs — the dispatch-time store a LEAN (fetch=true) ring's GET /dial?id= hydration reads back. Relay lane.
//
// WHY (dialPayloadV1 spec v0.6, seam d): a LEAN ring (payload exceeded the 5120-byte PushKit budget) ships only the CORE
// and sheds ALL governed content (message/options/context/evidenceSeqs). On `fetch:true` the phone hydrates the full
// signal via the AUTHENTICATED GET /dial?id= (PR-B2) — which reads back the signal THIS store held at dispatch, keyed by
// the ring's dialId (== signal.id). So a long/rich ring delivers instantly (a doorbell) and the full question/options/
// evidence load on pickup, post membership+session auth.
//
// CORRECTNESS (Pulse #78 review R1-R4):
//  R1 — expiry is LOGICAL (DynamoDB TTL deletion lags hours), checked `nowSec >= expiresAtSec` (expired AT the boundary,
//       matching the lock `ttl<=now` convention). WRITE is an unconditional store.put REPLACE, so an absent-OR-logically-
//       expired record is overwritten — a re-detected need reusing its canonical id can always re-ring (no putIfAbsent
//       physical-absent deadlock).
//  R2 — signal.id MUST equal dialId (no id substitution). A live (non-expired) record with byte-identical content is an
//       idempotent retry (returns the ACTUAL retained expiry); a live record with DIFFERENT content fails closed (no
//       silent keep-first, no silent overwrite-of-a-live-signal).
//  R3 — stores ONE JSON-safe deep-cloned plain-object snapshot (getters evaluated once -> no measure/write divergence),
//       rejects arrays / non-serializable, deep-clones on read (no reference poisoning), validates the stored shape on
//       read (corrupt/mismatched record -> unavailable, never arbitrary content).
//  R4 — rejects a non-finite clock and an invalid ttlSeconds (fail-closed, no silent fallback).
//
// SCOPE: this store is GATEWAY-INTERNAL — only /dial dispatch writes; the phone only READS via the authenticated GET. So
// substitution is defense-in-depth, not an attacker surface; the read-before-write guard is adequate (a fully-atomic
// conditional-put-with-top-level-ttl primitive + physical DynamoDB cleanup is the ideal, co-designed with PR-B2 + store.mjs).
// Membership+session binding is the endpoint's job (PR-B2), never here.

import { withLock } from './store.mjs';

export const DIAL_SIGNAL_TTL_SECONDS = 900;   // ring lifetime + a couple of hydrate retries
const MAX_SIGNAL_BYTES = 8192;                 // the signal arrives bounded from the mapper; a defensive fail-closed cap

/** Injection-safe keys: dialId length-prefixed so distinct dialIds can never alias. */
const sigKey = (dialId) => `dial:sig:${String(dialId).length}:${dialId}`;
const lockKey = (dialId) => `dial:sig:lock:${String(dialId).length}:${dialId}`;

/** Canonical (recursively key-sorted) JSON, so a reordered-but-identical retry compares equal (idempotent, not a false collision). */
function canonicalStringify(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(canonicalStringify).join(',') + ']';
  return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + canonicalStringify(v[k])).join(',') + '}';
}

/** ONE JSON-safe deep-cloned plain-object snapshot (getters evaluated once). Rejects arrays / non-plain / non-serializable. */
function snapshotSignal(signal) {
  if (signal === null || typeof signal !== 'object' || Array.isArray(signal)) throw new Error('dial signal store: signal must be a plain object');
  let json;
  try { json = JSON.stringify(signal); } catch { throw new Error('dial signal store: signal is not JSON-serializable'); }
  if (typeof json !== 'string') throw new Error('dial signal store: signal is not JSON-serializable');
  const snap = JSON.parse(json); // deep clone from the SINGLE serialization -> no reference leak, no getter re-evaluation
  if (snap === null || typeof snap !== 'object' || Array.isArray(snap)) throw new Error('dial signal store: signal must be a plain object');
  return { snap, json, bytes: Buffer.byteLength(json, 'utf8') };
}

/**
 * @param {{ store: {get:Function, put:Function}, now?: ()=>number, ttlSeconds?: number }} cfg
 */
export function createDialSignalStore({ store, now = () => Date.now(), ttlSeconds = DIAL_SIGNAL_TTL_SECONDS } = {}) {
  if (!store || typeof store.get !== 'function' || typeof store.put !== 'function' || typeof store.acquireLock !== 'function' || typeof store.releaseLock !== 'function') {
    throw new Error('createDialSignalStore requires a { get, put, acquireLock, releaseLock } store (writes are lock-serialized)');
  }
  if (typeof now !== 'function') throw new Error('createDialSignalStore: now must be a function');
  if (!(Number.isSafeInteger(ttlSeconds) && ttlSeconds > 0 && ttlSeconds <= 604800)) throw new Error('createDialSignalStore: ttlSeconds must be a positive safe integer <= 604800 (7d)'); // R4 + no astronomic expiry
  const ttl = ttlSeconds;
  const nowSec = () => { const ms = now(); if (!Number.isFinite(ms)) throw new Error('dial signal store: clock returned a non-finite value'); return Math.floor(ms / 1000); };

  return {
    ttlSeconds: ttl,

    /**
     * Store the authoritative full signal at dispatch. Overwrites an absent-or-logically-expired record (no deadlock);
     * a live byte-identical retry is idempotent; a live different-content collision fails closed.
     * @returns {Promise<{ stored: boolean, expiresAtSec: number }>}
     */
    async put(dialId, signal) {
      if (typeof dialId !== 'string' || dialId.trim().length === 0) throw new Error('dial signal store: dialId required');
      const { snap, bytes } = snapshotSignal(signal);                // R3
      if (bytes > MAX_SIGNAL_BYTES) throw new Error(`dial signal store: signal exceeds ${MAX_SIGNAL_BYTES} bytes`);
      if (snap.id !== dialId) throw new Error('dial signal store: signal.id must equal dialId (no id substitution)'); // R2
      const canon = canonicalStringify(snap);                        // order-insensitive content identity for idempotency
      const ns = nowSec();                                            // R4: throws on non-finite clock
      // SERIALIZE the full read/compare/write under a per-dialId lock (Pulse R2 TOCTOU): two concurrent dispatches for one
      // id can never both write/ring. The lock loser gets locked:false -> fail closed (never a silent last-writer substitution).
      const outcome = await withLock(store, lockKey(dialId), async () => {
        const existing = await store.get(sigKey(dialId));
        if (existing && typeof existing === 'object' && Number.isFinite(existing.expiresAtSec) && ns < existing.expiresAtSec) {
          if (canonicalStringify(existing.signal) === canon) return { stored: false, expiresAtSec: existing.expiresAtSec }; // idempotent (order-insensitive) retry -> ACTUAL retained expiry
          throw new Error('dial signal store: dialId already holds different content within TTL (fail-closed collision)'); // R2 substitution
        }
        const expiresAtSec = ns + ttl;
        await store.put(sigKey(dialId), { signal: snap, expiresAtSec, dialId }, { ttlEpochSec: expiresAtSec }); // R1 overwrite absent/expired + R6 top-level Dynamo ttl for cleanup
        return { stored: true, expiresAtSec };
      });
      if (!outcome.locked) throw new Error('dial signal store: write lock unavailable for dialId (concurrent dispatch) — fail closed');
      return outcome.value;
    },

    /**
     * Read the stored signal for a dialId. Absent/expired/corrupt -> undefined (endpoint -> 410 -> honest unavailable).
     * Returns a DEEP CLONE (the caller can never poison the stored record). Validates the stored shape + id match.
     */
    async get(dialId) {
      if (typeof dialId !== 'string' || dialId.trim().length === 0) return undefined;
      const rec = await store.get(sigKey(dialId));
      if (!rec || typeof rec !== 'object' || !Number.isFinite(rec.expiresAtSec)) return undefined;
      if (nowSec() >= rec.expiresAtSec) return undefined;             // R1a: expired AT the boundary (>=)
      const s = rec.signal;
      if (s === null || typeof s !== 'object' || Array.isArray(s) || s.id !== dialId) return undefined; // corrupt/mismatched shape or id -> unavailable
      let json;
      try { json = JSON.stringify(s); } catch { return undefined; } // R5: non-serializable / cyclic stored record -> unavailable
      if (typeof json !== 'string' || Buffer.byteLength(json, 'utf8') > MAX_SIGNAL_BYTES) return undefined; // R5: oversize corrupt record -> unavailable (validate SIZE on read, not just shape)
      return JSON.parse(json); // single serialization: deep clone from the SAME json we validated -> no reference leak, no measure/return divergence
    },
  };
}

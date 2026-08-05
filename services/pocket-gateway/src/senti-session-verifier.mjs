// senti-session-verifier.mjs — B3 native-door auth for Pocket's /execute (Carter's "cousin, one native token").
//
// Validates an incoming SENTI USER-session bearer by CALLING the api (GET /auth/me) — it NEVER holds a signing secret.
// This is the whole point: the api's user-session JWT is HS256 (symmetric), so anything able to VALIDATE a session
// locally could also FORGE one (verify==sign). By delegating validation to the api, the gateway stays MINT-INCAPABLE:
// it can confirm "this token is a real user session for humanId X" but can never mint a session for anyone.
//
// Drop-in for the gateway's verifyToken(headers): returns { humanId, principal, scopes, site, tokenClaims } or null
// (fail-closed). The gateway then uses humanId for its existing membership lookup (knownSessionIdsFor) + forwards the
// SAME token downstream to /human-message (one native token end-to-end).

import { createHash } from 'node:crypto';
import { timeoutSignal } from './http-timeout.mjs';

// Cache TTL bounds how long a SUCCESSFUL validation is reused. SECURITY: we CANNOT read the token's own `exp` — it's an
// HS256 JWT and we (correctly) hold no secret to decode it — so this TTL is the ONLY freshness bound. A cached identity
// may therefore outlive the token's expiry OR a revocation by at most TTL. Keep it SHORT (governed-write path); Warden's
// bar is <=60s and we default well under. Failures (401/403) are NEVER cached, so a revoked token stops validating within
// one TTL at worst, immediately once the cache entry lapses.
const DEFAULT_CACHE_TTL_MS = 20_000;
// A validated user session is not scope-limited on its OWN data, so it gets the full Pocket scope set. NOTE: this makes
// each route's hasScope() gate effectively always-true for a valid session — the REAL per-write authz is MEMBERSHIP
// (knownSessionIdsFor + the /execute membership precheck), not scope granularity. Correct for the native-door model.
// The FULL Pocket scope set — MUST list every SCOPES value handlers.mjs gates on (sync/execute/tts/dial), else a valid
// session 403s on that route. pocket:dial was added with DIAL-ME; omitting it here made /dial + /dial/register
// unreachable in prod despite a valid session. Keep in sync with createGateway's SCOPES.
const DEFAULT_SCOPES = ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial'];
const DEFAULT_TIMEOUT_MS = 5000;
const DEFAULT_MAX_CACHE_ENTRIES = 5000; // bound the positive cache (evict oldest) so a long-warm instance can't grow unbounded

/** length-prefixed segment — makes the principal string unambiguous (no humanId can inject a delimiter). */
const lp = (s) => String(s).length + ':' + String(s);

/** cache/dedupe by a HASH of the credential — the raw token is never used as a map key. */
const tokenKey = (authz) => createHash('sha256').update(authz).digest('base64url');

export class SentiSessionVerifierUnavailableError extends Error {
  constructor(message, { cause } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = 'SentiSessionVerifierUnavailableError';
    this.code = 'senti-session-verifier-unavailable';
  }
}

/**
 * @param {object}   cfg
 * @param {Function} cfg.fetch        injected fetch (deploy-owned transport)
 * @param {string}   cfg.apiBaseUrl   api ORIGIN (GET /api/v1/auth/me is appended)
 * @param {string[]} [cfg.scopes]     scopes granted to a validated user session (default read+write+voice+dial)
 * @param {number}   [cfg.cacheTtlMs] validated-identity cache TTL — caps per-execute round-trips + the auth_me rate
 *                                    burn (30/window); also caps revocation latency. Default 20s.
 * @param {number}   [cfg.timeoutMs]
 * @param {Function} [cfg.now]
 * @param {boolean}  [cfg.throwOnUnavailable] distinguish invalid credentials (null) from transport/contract outage
 * @returns {(headers: object) => Promise<null | {humanId,principal,scopes,site,tokenClaims}>}
 */
export function createSentiSessionVerifier({ fetch, apiBaseUrl, scopes = DEFAULT_SCOPES, cacheTtlMs = DEFAULT_CACHE_TTL_MS, timeoutMs = DEFAULT_TIMEOUT_MS, maxCacheEntries = DEFAULT_MAX_CACHE_ENTRIES, now = () => Date.now(), throwOnUnavailable = false } = {}) {
  if (typeof fetch !== 'function') throw new Error('createSentiSessionVerifier: fetch is required');
  const base = String(apiBaseUrl || '').replace(/\/+$/, '');
  if (!base) throw new Error('createSentiSessionVerifier: apiBaseUrl is required');
  const grantedScopes = Object.freeze([...scopes]);
  const cache = new Map(); // sha256(token) -> { result, exp }
  if (typeof throwOnUnavailable !== 'boolean') {
    throw new Error('createSentiSessionVerifier: throwOnUnavailable must be boolean');
  }
  const unavailable = (message, cause) => {
    if (throwOnUnavailable) throw new SentiSessionVerifierUnavailableError(message, { cause });
    return null;
  };

  return async function verifyToken(headers) {
    const authz = headers && (headers.authorization || headers.Authorization);
    if (!authz || typeof authz !== 'string') return null;             // no bearer -> fail-closed

    const key = tokenKey(authz);
    const hit = cache.get(key);
    if (hit) {
      if (hit.exp > now()) return hit.result;                         // fresh positive validation only
      cache.delete(key);                                             // expired -> drop it, don't let stale positives linger
    }

    const signal = timeoutSignal(timeoutMs); // bounded on any runtime (native AbortSignal.timeout, else an AbortController fallback)
    let res;
    try {
      // Delegate validation to the api under the caller's OWN token — the gateway holds no secret, mints nothing.
      res = await fetch(`${base}/api/v1/auth/me`, { method: 'GET', headers: { authorization: authz }, ...(signal ? { signal } : {}) });
    } catch (cause) {
      return unavailable('Senti session validation transport is unavailable', cause);
    }
    let ok;
    let status;
    try {
      ok = res?.ok;
      status = res?.status;
    } catch (cause) {
      return unavailable('Senti session validation response is unavailable', cause);
    }
    if (!res || typeof ok !== 'boolean') return unavailable('Senti session validation response is invalid');
    if (!ok) {
      cache.delete(key);
      if (status === 401 || status === 403) return null;
      return unavailable('Senti session validation service rejected the request unexpectedly');
    }

    let me;
    try { me = await res.json(); } catch (cause) {
      return unavailable('Senti session validation response is invalid', cause);
    }
    // Contract: GET /api/v1/auth/me returns the user with a TOP-LEVEL `id` (api auth route get_current_user -> UserResponse;
    // corroborated by the shipped CLI create-sentinelayer/src/auth/service.js fetchCurrentUser -> normalizeUser, which
    // reads user.id top-level). Pinned here so an api response reshape can't silently break B3 unnoticed.
    const humanId = me && (typeof me.id === 'string' && me.id ? me.id : null);
    if (!humanId) return unavailable('Senti session validation identity is invalid');

    // FROZEN (Warden hardening note 1): this result is cached and returned BY REFERENCE on every cache hit, so a
    // downstream in-place mutation (.push/.sort/.splice on ctx.scopes) would poison the entry for ALL later hits of this
    // token. Freeze the nested array + claims + the object so the cached identity is deeply immutable. Handlers read via
    // .includes() today (safe), but freezing removes the latent footgun for any future consumer.
    const result = Object.freeze({
      humanId,
      // Distinct principal namespace from AIdenID tokens (prefix), so SENTI + AIdenID durable state never collide for
      // the same humanId. The user id IS the stable, collision-free anchor for principal/membership (not a pairwise sub).
      principal: 'pocket.principal.senti.v1\n' + lp(humanId),
      scopes: Object.freeze([...grantedScopes]),
      site: null,
      tokenClaims: Object.freeze({ authMethod: 'senti_session', via: 'auth/me' }),
    });
    // Bound the cache: at capacity evict the OLDEST entry (Map preserves insertion order). Positives also drop on expiry
    // (above) + on any observed failure; this cap covers tokens validated once and never seen again (long-warm instance).
    if (cache.size >= maxCacheEntries) { const oldest = cache.keys().next().value; if (oldest !== undefined) cache.delete(oldest); }
    cache.set(key, { result, exp: now() + cacheTtlMs });
    return result;
  };
}

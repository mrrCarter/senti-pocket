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

// Cache TTL bounds how long a SUCCESSFUL validation is reused. SECURITY: we CANNOT read the token's own `exp` — it's an
// HS256 JWT and we (correctly) hold no secret to decode it — so this TTL is the ONLY freshness bound. A cached identity
// may therefore outlive the token's expiry OR a revocation by at most TTL. Keep it SHORT (governed-write path); Warden's
// bar is <=60s and we default well under. Failures (401/403) are NEVER cached, so a revoked token stops validating within
// one TTL at worst, immediately once the cache entry lapses.
const DEFAULT_CACHE_TTL_MS = 20_000;
const DEFAULT_SCOPES = ['sessions:read', 'sessions:write', 'pocket:voice']; // a real user session is not scope-limited
const DEFAULT_TIMEOUT_MS = 5000;

/** length-prefixed segment — makes the principal string unambiguous (no humanId can inject a delimiter). */
const lp = (s) => String(s).length + ':' + String(s);

/** cache/dedupe by a HASH of the credential — the raw token is never used as a map key. */
const tokenKey = (authz) => createHash('sha256').update(authz).digest('base64url');

/**
 * @param {object}   cfg
 * @param {Function} cfg.fetch        injected fetch (deploy-owned transport)
 * @param {string}   cfg.apiBaseUrl   api ORIGIN (GET /api/v1/auth/me is appended)
 * @param {string[]} [cfg.scopes]     scopes granted to a validated user session (default read+write+voice)
 * @param {number}   [cfg.cacheTtlMs] validated-identity cache TTL — caps per-execute round-trips + the auth_me rate
 *                                    burn (30/window); also caps revocation latency. Default 20s.
 * @param {number}   [cfg.timeoutMs]
 * @param {Function} [cfg.now]
 * @returns {(headers: object) => Promise<null | {humanId,principal,scopes,site,tokenClaims}>}
 */
export function createSentiSessionVerifier({ fetch, apiBaseUrl, scopes = DEFAULT_SCOPES, cacheTtlMs = DEFAULT_CACHE_TTL_MS, timeoutMs = DEFAULT_TIMEOUT_MS, now = () => Date.now() } = {}) {
  if (typeof fetch !== 'function') throw new Error('createSentiSessionVerifier: fetch is required');
  const base = String(apiBaseUrl || '').replace(/\/+$/, '');
  if (!base) throw new Error('createSentiSessionVerifier: apiBaseUrl is required');
  const grantedScopes = Object.freeze([...scopes]);
  const cache = new Map(); // sha256(token) -> { result, exp }

  return async function verifyToken(headers) {
    const authz = headers && (headers.authorization || headers.Authorization);
    if (!authz || typeof authz !== 'string') return null;             // no bearer -> fail-closed

    const key = tokenKey(authz);
    const hit = cache.get(key);
    if (hit && hit.exp > now()) return hit.result;                    // fresh positive validation only

    const signal = (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') ? AbortSignal.timeout(timeoutMs) : undefined;
    let res;
    try {
      // Delegate validation to the api under the caller's OWN token — the gateway holds no secret, mints nothing.
      res = await fetch(`${base}/api/v1/auth/me`, { method: 'GET', headers: { authorization: authz }, ...(signal ? { signal } : {}) });
    } catch {
      return null;                                                    // network/timeout -> fail-closed (never authorize an unvalidated token)
    }
    if (!res || !res.ok) { cache.delete(key); return null; }          // 401/403 (invalid/blocked/banned) / 5xx -> fail-closed, never cache a failure

    let me;
    try { me = await res.json(); } catch { return null; }
    const humanId = me && (typeof me.id === 'string' && me.id ? me.id : null);
    if (!humanId) return null;                                        // no identity -> fail-closed

    const result = {
      humanId,
      // Distinct principal namespace from AIdenID tokens (prefix), so SENTI + AIdenID durable state never collide for
      // the same humanId. The user id IS the stable anchor for a user session (not a pairwise sub).
      principal: 'pocket.principal.senti.v1\n' + lp(humanId),
      scopes: [...grantedScopes],
      site: null,
      tokenClaims: { authMethod: 'senti_session', via: 'auth/me' },
    };
    cache.set(key, { result, exp: now() + cacheTtlMs });
    return result;
  };
}

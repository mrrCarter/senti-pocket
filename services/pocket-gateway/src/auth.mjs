// auth.mjs — REAL AIdenID bearer-token verification (Echo P0: auth must be an implementation, not a naked seam).
// Verifies a JWT's signature against a JWKS, checks iss/aud/exp/nbf, and (when the token is sender-constrained)
// enforces a DPoP proof-of-possession (RFC 9449) bound to the token's cnf.jkt. Zero-dep: node:crypto only.
//
// The exact AIdenID claim names (humanId source, scope claim) are configurable — per Echo's AIdenID research the
// human anchor is ConsumerAccount.id and tokens are minted audience/resource-bound (optionally DPoP) via
// /v1/sessions/exchange. In prod, `jwks` is fetched + cached from AIdenID's JWKS endpoint (inject a fetcher).
import { createPublicKey, verify as edVerify, createVerify, createHash } from 'node:crypto';

const b64urlDecode = (s) => Buffer.from(String(s).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlJson = (s) => JSON.parse(b64urlDecode(s).toString('utf8'));

/** Verify a JWS signing input against a public KeyObject for the supported JWT algs. */
function verifyJws(alg, signingInput, sigBytes, keyObj) {
  const input = Buffer.from(signingInput, 'utf8');
  if (alg === 'EdDSA') return edVerify(null, input, keyObj, sigBytes);
  if (alg === 'ES256') { const v = createVerify('SHA256'); v.update(input); v.end(); return v.verify({ key: keyObj, dsaEncoding: 'ieee-p1363' }, sigBytes); }
  if (alg === 'RS256') { const v = createVerify('RSA-SHA256'); v.update(input); v.end(); return v.verify(keyObj, sigBytes); }
  return false;
}

/** RFC 7638 JWK thumbprint (SHA-256, base64url) over the required members in lexicographic order. */
export function jwkThumbprint(jwk) {
  let canon;
  if (jwk.kty === 'OKP') canon = { crv: jwk.crv, kty: 'OKP', x: jwk.x };
  else if (jwk.kty === 'EC') canon = { crv: jwk.crv, kty: 'EC', x: jwk.x, y: jwk.y };
  else if (jwk.kty === 'RSA') canon = { e: jwk.e, kty: 'RSA', n: jwk.n };
  else throw new Error('unsupported kty for thumbprint');
  return b64url(createHash('sha256').update(JSON.stringify(canon), 'utf8').digest());
}

function decodeJwt(token) {
  const parts = String(token).split('.');
  if (parts.length !== 3) return null;
  return { header: b64urlJson(parts[0]), payload: b64urlJson(parts[1]), sig: b64urlDecode(parts[2]), signingInput: parts[0] + '.' + parts[1] };
}

const audienceOk = (aud, want) => (Array.isArray(aud) ? aud.includes(want) : aud === want);

/**
 * In-memory DPoP jti replay guard (dev/tests). `seen(jti, expiresAtSec)` records the jti and returns true iff it was
 * already present (i.e. a replay). Prod: use createStoreReplayGuard (store.mjs) so it holds across Lambda instances.
 */
export function createInMemoryReplayGuard() {
  const store = new Map(); // jti -> expiresAtSec
  return {
    async seen(jti, expiresAtSec) {
      const nowSec = Math.floor(Date.now() / 1000);
      if (store.size > 5000) for (const [k, exp] of store) if (exp < nowSec) store.delete(k);
      if (store.has(jti)) return true;
      store.set(jti, expiresAtSec);
      return false;
    },
  };
}

/**
 * Verify a DPoP proof (RFC 9449): a JWT in the `dpop` header signed by the client's key, whose JWK thumbprint MUST
 * equal the access token's cnf.jkt, bound to this request's method+url, hashing the access token in `ath`. When a
 * `replayGuard` is supplied, the proof's `jti` is single-use within its freshness window (replay defense).
 */
async function verifyDpop(dpopHeader, { jkt, htm, htu, accessToken, nowSec, clockSkewSec, replayGuard }) {
  if (typeof dpopHeader !== 'string') return false;
  const d = decodeJwt(dpopHeader);
  if (!d || d.header.typ !== 'dpop+jwt' || !d.header.jwk) return false;
  let keyObj;
  try { keyObj = createPublicKey({ key: d.header.jwk, format: 'jwk' }); } catch { return false; }
  if (!verifyJws(d.header.alg, d.signingInput, d.sig, keyObj)) return false;      // proof self-signature
  if (jwkThumbprint(d.header.jwk) !== jkt) return false;                          // bound to THIS token (cnf.jkt)
  if (htm && String(d.payload.htm).toUpperCase() !== String(htm).toUpperCase()) return false;
  if (htu && d.payload.htu !== htu) return false;                                 // exact request URL
  const maxAge = Math.max(clockSkewSec, 300);
  if (typeof d.payload.iat !== 'number' || Math.abs(nowSec - d.payload.iat) > maxAge) return false;
  const ath = b64url(createHash('sha256').update(accessToken, 'utf8').digest());
  if (d.payload.ath !== ath) return false;                                        // binds the exact access token
  if (replayGuard) {                                                              // REPLAY defense (RFC 9449 §11.1)
    if (typeof d.payload.jti !== 'string' || !d.payload.jti) return false;        // a proof MUST carry a unique jti
    if (await replayGuard.seen(d.payload.jti, nowSec + maxAge)) return false;     // reused jti within window => reject
  }
  return true;
}

/**
 * Build a verifyToken(headers) for the gateway. Returns {humanId, scopes, tokenClaims} or null (fail-closed).
 * @param {{ jwks:object[], issuer?:string, audience?:string, now?:()=>number, clockSkewSec?:number,
 *           humanIdClaim?:string, scopeClaim?:string, requireDpop?:boolean }} cfg
 */
export function createAidenIdVerifier(cfg = {}) {
  const { jwks = [], issuer, audience, resource, now = () => Date.now(), clockSkewSec = 60, humanIdClaim = 'consumerAccountId', scopeClaim = 'scope', requireDpop = false, replayGuard } = cfg;
  const keyByKid = new Map();
  for (const jwk of jwks) { try { keyByKid.set(jwk.kid, { obj: createPublicKey({ key: jwk, format: 'jwk' }), alg: jwk.alg }); } catch { /* skip bad key */ } }

  return async function verifyToken(headers) {
    try {
      const raw = headers && (headers.authorization || headers.Authorization);
      if (typeof raw !== 'string') return null;
      const m = /^(?:Bearer|DPoP)\s+(.+)$/i.exec(raw.trim());
      if (!m) return null;
      const token = m[1];
      const jwt = decodeJwt(token);
      if (!jwt) return null;
      const k = keyByKid.get(jwt.header.kid);
      if (!k) return null;                                                        // unknown signing key -> reject
      if (!verifyJws(jwt.header.alg, jwt.signingInput, jwt.sig, k.obj)) return null;

      const p = jwt.payload;
      const nowSec = Math.floor(now() / 1000);
      if (issuer && p.iss !== issuer) return null;
      if (audience && !audienceOk(p.aud, audience)) return null;
      if (resource && !audienceOk(p.resource, resource)) return null;             // RFC 8707 resource indicator
      if (typeof p.exp === 'number' && nowSec > p.exp + clockSkewSec) return null;
      if (typeof p.nbf === 'number' && nowSec < p.nbf - clockSkewSec) return null;

      const humanId = p[humanIdClaim] || p.sub;
      if (typeof humanId !== 'string' || !humanId) return null;

      const jkt = p.cnf && p.cnf.jkt;                                             // sender-constrained token?
      if (requireDpop && !jkt) return null;
      if (jkt) {
        const ok = await verifyDpop(headers && (headers.dpop || headers.DPoP), {
          jkt, htm: headers['x-http-method'], htu: headers['x-http-url'], accessToken: token, nowSec, clockSkewSec, replayGuard,
        });
        if (!ok) return null;                                                     // missing/invalid/replayed proof -> reject
      }

      const sc = p[scopeClaim];
      const scopes = typeof sc === 'string' ? sc.split(/\s+/).filter(Boolean) : (Array.isArray(sc) ? sc : []);
      return { humanId, scopes, tokenClaims: { iss: p.iss, aud: p.aud, exp: p.exp, dpopBound: !!jkt } };
    } catch { return null; }
  };
}

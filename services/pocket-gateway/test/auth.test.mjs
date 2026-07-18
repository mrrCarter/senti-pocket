// auth.test.mjs — real AIdenID verifier: signs actual JWTs + DPoP proofs with node:crypto (no live IdP).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as edSign, createHash, createSign } from 'node:crypto';
import { createAidenIdVerifier, jwkThumbprint, createInMemoryReplayGuard } from '../src/auth.mjs';

const sha256 = (s) => createHash('sha256').update(s, 'utf8').digest();
function signEs256({ header, payload, privateKey }) {
  const si = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
  const s = createSign('SHA256'); s.update(si); s.end();
  return si + '.' + b64url(s.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }));
}

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const NOW = 1_760_000_000_000; // fixed clock
const nowSec = Math.floor(NOW / 1000);

function ed25519() {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  return { publicKey, privateKey, jwk: publicKey.export({ format: 'jwk' }) };
}
function signJwt({ header, payload, privateKey }) {
  const si = b64url(JSON.stringify(header)) + '.' + b64url(JSON.stringify(payload));
  return si + '.' + b64url(edSign(null, Buffer.from(si), privateKey));
}

const ISSUER = 'https://api.aidenid.com';
const AUD = 'https://gateway.senti.app';
const idp = ed25519();
const KID = 'idp-1';
const jwks = [{ ...idp.jwk, kid: KID, alg: 'EdDSA' }];
const verifier = createAidenIdVerifier({ jwks, issuer: ISSUER, audience: AUD, now: () => NOW });

const mint = (over = {}) => signJwt({
  header: { alg: 'EdDSA', kid: KID, typ: 'JWT' },
  payload: { iss: ISSUER, aud: AUD, exp: nowSec + 300, consumerAccountId: 'consumer-abc', scope: 'actions:execute bundles:read', ...over },
  privateKey: idp.privateKey,
});

test('valid token verifies -> humanId + scopes', async () => {
  const ctx = await verifier({ authorization: 'Bearer ' + mint() });
  assert.equal(ctx.humanId, 'consumer-abc');
  assert.deepEqual(ctx.scopes, ['actions:execute', 'bundles:read']);
});

test('rejects: tampered signature, wrong iss, wrong aud, expired, unknown kid, non-bearer', async () => {
  const good = mint();
  assert.equal(await verifier({ authorization: 'Bearer ' + good.slice(0, -4) + 'AAAA' }), null, 'tampered sig');
  assert.equal(await verifier({ authorization: 'Bearer ' + mint({ iss: 'https://evil' }) }), null, 'wrong iss');
  assert.equal(await verifier({ authorization: 'Bearer ' + mint({ aud: 'https://other' }) }), null, 'wrong aud');
  assert.equal(await verifier({ authorization: 'Bearer ' + mint({ exp: nowSec - 3600 }) }), null, 'expired');
  const otherIdp = ed25519();
  const foreign = signJwt({ header: { alg: 'EdDSA', kid: 'idp-1', typ: 'JWT' }, payload: { iss: ISSUER, aud: AUD, exp: nowSec + 300, consumerAccountId: 'x' }, privateKey: otherIdp.privateKey });
  assert.equal(await verifier({ authorization: 'Bearer ' + foreign }), null, 'signed by a key not in JWKS');
  assert.equal(await verifier({ authorization: 'Basic abc' }), null, 'non-bearer');
  assert.equal(await verifier({}), null, 'no header');
});

test('no humanId claim => reject', async () => {
  const noSub = signJwt({ header: { alg: 'EdDSA', kid: KID, typ: 'JWT' }, payload: { iss: ISSUER, aud: AUD, exp: nowSec + 300, scope: 'x' }, privateKey: idp.privateKey });
  assert.equal(await verifier({ authorization: 'Bearer ' + noSub }), null);
});

// ---- DPoP (RFC 9449) sender-constrained token ----
const client = ed25519();
const jkt = jwkThumbprint(client.jwk);
const mintDpopBound = () => signJwt({ header: { alg: 'EdDSA', kid: KID, typ: 'JWT' }, payload: { iss: ISSUER, aud: AUD, exp: nowSec + 300, consumerAccountId: 'consumer-dpop', scope: 'actions:execute', cnf: { jkt } }, privateKey: idp.privateKey });
function dpopProof({ htm = 'POST', htu = 'https://gateway.senti.app/actions/execute', accessToken, iat = nowSec, key = client }) {
  const ath = b64url(sha256(accessToken));
  return signJwt({ header: { typ: 'dpop+jwt', alg: 'EdDSA', jwk: key.jwk }, payload: { htm, htu, iat, ath, jti: 'proof-1' }, privateKey: key.privateKey });
}

test('DPoP-bound token: valid proof passes; missing/mismatched proof rejected', async () => {
  const token = mintDpopBound();
  const htu = 'https://gateway.senti.app/actions/execute';
  const base = { authorization: 'Bearer ' + token, 'x-http-method': 'POST', 'x-http-url': htu };
  // valid proof
  assert.ok(await verifier({ ...base, dpop: dpopProof({ accessToken: token }) }));
  // missing proof
  assert.equal(await verifier(base), null, 'no DPoP proof for a bound token');
  // wrong method
  assert.equal(await verifier({ ...base, dpop: dpopProof({ accessToken: token, htm: 'GET' }) }), null, 'method mismatch');
  // proof signed by a DIFFERENT key (thumbprint != cnf.jkt)
  const attacker = ed25519();
  assert.equal(await verifier({ ...base, dpop: dpopProof({ accessToken: token, key: attacker }) }), null, 'wrong key thumbprint');
  // stale iat
  assert.equal(await verifier({ ...base, dpop: dpopProof({ accessToken: token, iat: nowSec - 100000 }) }), null, 'stale proof');
});

test('DPoP replay: a reused jti is rejected when a replayGuard is configured', async () => {
  const guard = createInMemoryReplayGuard();
  const v = createAidenIdVerifier({ jwks, issuer: ISSUER, audience: AUD, now: () => NOW, replayGuard: guard });
  const token = mintDpopBound();
  const htu = 'https://gateway.senti.app/actions/execute';
  const base = { authorization: 'Bearer ' + token, 'x-http-method': 'POST', 'x-http-url': htu };
  const proof = dpopProof({ accessToken: token }); // fixed jti 'proof-1'
  assert.ok(await v({ ...base, dpop: proof }), 'first use accepted');
  assert.equal(await v({ ...base, dpop: proof }), null, 'replayed jti rejected');
  // a token with cnf.jkt but a proof lacking jti is rejected under a replay guard
  const noJti = signJwt({ header: { typ: 'dpop+jwt', alg: 'EdDSA', jwk: client.jwk }, payload: { htm: 'POST', htu, iat: nowSec, ath: b64url(sha256(token)) }, privateKey: client.privateKey });
  assert.equal(await v({ ...base, dpop: noJti }), null, 'proof without jti rejected when replay guard is on');
});

test('resource indicator (RFC 8707) enforced when configured', async () => {
  const RES = 'https://gateway.senti.app/actions';
  const v = createAidenIdVerifier({ jwks, issuer: ISSUER, audience: AUD, resource: RES, now: () => NOW });
  const withRes = signJwt({ header: { alg: 'EdDSA', kid: KID, typ: 'JWT' }, payload: { iss: ISSUER, aud: AUD, exp: nowSec + 300, consumerAccountId: 'c', scope: 'x', resource: RES }, privateKey: idp.privateKey });
  assert.ok(await v({ authorization: 'Bearer ' + withRes }));
  assert.equal(await v({ authorization: 'Bearer ' + mint() }), null, 'missing/mismatched resource rejected');
});

// Interop with Echo's AIdenID contract (checkpoint #231811): EdDSA access token carrying aud/resource/site +
// PAIRWISE sub + cnf.jkt, sender-constrained with an ES256 DPoP proof. Proves the verifier consumes that shape as-is.
test('AIdenID-shaped token interop: EdDSA access token (pairwise sub + resource + site) with an ES256 DPoP proof', async () => {
  const ec = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const ecJwk = ec.publicKey.export({ format: 'jwk' });
  const RES = 'https://gateway.senti.app/actions';
  const v = createAidenIdVerifier({ jwks, issuer: ISSUER, audience: AUD, resource: RES, now: () => NOW, replayGuard: createInMemoryReplayGuard() });
  const token = signJwt({
    header: { alg: 'EdDSA', kid: KID, typ: 'JWT' },
    payload: { iss: ISSUER, aud: AUD, resource: RES, site_id: 'senti-pocket', sub: 'pairwise-xyz', exp: nowSec + 300, scope: 'actions:execute', cnf: { jkt: jwkThumbprint(ecJwk) } },
    privateKey: idp.privateKey,
  });
  const htu = 'https://gateway.senti.app/actions/execute';
  const proof = signEs256({ header: { typ: 'dpop+jwt', alg: 'ES256', jwk: ecJwk }, payload: { htm: 'POST', htu, iat: nowSec, ath: b64url(sha256(token)), jti: 'ecp-1' }, privateKey: ec.privateKey });
  const ctx = await v({ authorization: 'Bearer ' + token, dpop: proof, 'x-http-method': 'POST', 'x-http-url': htu });
  assert.ok(ctx, 'AIdenID-shaped token + ES256 DPoP verifies');
  assert.equal(ctx.humanId, 'pairwise-xyz', 'humanId derives from the pairwise sub');
  assert.equal(ctx.site, 'senti-pocket');
  assert.ok(ctx.principal.includes('pairwise-xyz') && ctx.principal.includes('senti-pocket'), 'principal binds the full context');
  assert.equal(ctx.tokenClaims.dpopBound, true);
});

test('siteId enforced; principal namespaces the full context so a pairwise sub cannot collide across sites', async () => {
  const RES = 'https://gateway.senti.app/actions';
  const tokenFor = (site) => signJwt({ header: { alg: 'EdDSA', kid: KID, typ: 'JWT' }, payload: { iss: ISSUER, aud: AUD, resource: RES, site_id: site, sub: 'pairwise-same', exp: nowSec + 300, scope: 'x' }, privateKey: idp.privateKey });
  const vA = createAidenIdVerifier({ jwks, issuer: ISSUER, audience: AUD, resource: RES, siteId: 'siteA', now: () => NOW });
  assert.equal(await vA({ authorization: 'Bearer ' + tokenFor('siteB') }), null, 'a token minted for another site is rejected');
  const ctxA = await vA({ authorization: 'Bearer ' + tokenFor('siteA') });
  assert.ok(ctxA && ctxA.principal.includes('siteA'));
  const vB = createAidenIdVerifier({ jwks, issuer: ISSUER, audience: AUD, resource: RES, siteId: 'siteB', now: () => NOW });
  const ctxB = await vB({ authorization: 'Bearer ' + tokenFor('siteB') });
  assert.ok(ctxB);
  assert.notEqual(ctxA.principal, ctxB.principal, 'same pairwise sub at different sites => different namespace');
});

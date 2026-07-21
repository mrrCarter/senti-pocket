// native_kav.test.mjs — REAL-TOKEN known-answer vector. The fixture is byte-identical to the AIdenID-published
// native OAuth interop vector (H:\aidenid-pocket-native-auth\...\native_oauth_interop_v1.json,
// SHA256=6dd15937832a205b99a0c31aa9b755704432550753b31365a9c653a108834e36). It contains an actual AIdenID-minted
// EdDSA access token + JWKS + an ES256 DPoP proof for POST https://pocket-api.sentinelayer.com/v1/pocket/actions.
// Proving my verifier ACCEPTS it end-to-end confirms my RFC 7638 JWK thumbprint + DPoP `ath` byte-match AIdenID's.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createAidenIdVerifier, createInMemoryReplayGuard } from '../src/auth.mjs';

const FIXTURE_URL = new URL('./fixtures/native_oauth_interop_v1.json', import.meta.url);
const RAW = readFileSync(FIXTURE_URL);
const KAV = JSON.parse(RAW.toString('utf8'));
const EXPECTED_SHA = '6dd15937832a205b99a0c31aa9b755704432550753b31365a9c653a108834e36';

const mkVerifier = (guard) => createAidenIdVerifier({
  jwks: KAV.jwks.keys,
  issuer: KAV.expected.issuer,
  audience: KAV.expected.audience,
  resource: KAV.expected.resource,
  siteId: KAV.expected.siteId,
  now: () => Date.parse(KAV.verificationTime),
  replayGuard: guard,
});
const headers = () => ({
  authorization: 'Bearer ' + KAV.accessToken,
  dpop: KAV.dpopProof,
  'x-http-method': KAV.request.method,
  'x-http-url': KAV.request.url,
});

test('KAV fixture is byte-identical to the AIdenID-published vector', () => {
  assert.equal(createHash('sha256').update(RAW).digest('hex'), EXPECTED_SHA);
});

test('AIdenID byte-exact KAV: real minted EdDSA token + ES256 DPoP verifies; claims/bindings exact', async () => {
  const e = KAV.expected;
  const ctx = await mkVerifier(createInMemoryReplayGuard())(headers());
  assert.ok(ctx, 'real AIdenID access token + ES256 DPoP proof accepted by the Relay verifier');
  assert.equal(ctx.humanId, e.subject, 'humanId derives from the pairwise sub');
  assert.equal(ctx.site, e.siteId);
  assert.deepEqual(ctx.scopes, e.scope.split(' '));
  assert.equal(ctx.tokenClaims.dpopBound, true, 'DPoP binding (cnf.jkt == thumbprint) verified byte-exact');
  assert.equal(ctx.tokenClaims.iss, e.issuer);
  assert.equal(ctx.tokenClaims.resource, e.resource);
  assert.ok(ctx.principal.includes(e.subject) && ctx.principal.includes(e.siteId) && ctx.principal.includes(e.resource), 'principal binds the full context');
});

test('AIdenID KAV: DPoP replay rejected; tampered token rejected; wrong site rejected', async () => {
  const e = KAV.expected;
  const guard = createInMemoryReplayGuard();
  const verify = mkVerifier(guard);
  assert.ok(await verify(headers()), 'first use accepted');
  assert.equal(await verify(headers()), null, 'replayed DPoP jti rejected');

  const tamper = createAidenIdVerifier({ jwks: KAV.jwks.keys, issuer: e.issuer, audience: e.audience, resource: e.resource, siteId: e.siteId, now: () => Date.parse(KAV.verificationTime) });
  assert.equal(await tamper({ ...headers(), authorization: 'Bearer ' + KAV.accessToken.slice(0, -3) + 'AAA' }), null, 'tampered access-token signature rejected');

  const wrongSite = createAidenIdVerifier({ jwks: KAV.jwks.keys, issuer: e.issuer, audience: e.audience, resource: e.resource, siteId: 'site_other', now: () => Date.parse(KAV.verificationTime) });
  assert.equal(await wrongSite(headers()), null, 'token minted for a different site rejected');
});

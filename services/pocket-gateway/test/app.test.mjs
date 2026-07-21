// app.test.mjs — production composition MUST fail boot on missing config/deps (Echo P0), and wire up when complete.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { createProdGateway, createLambda } from '../src/app.mjs';

// Pocket-gateway is SENTI-native (B3): no AIdenID issuer/audience/resource/site or JWKS — auth is GET /auth/me.
const FULL_ENV = {
  DDB_TABLE: 'pocket-gateway',
  SIGNING_KEY_ID: 'kms-key-1',
  GATEWAY_PUBLIC_URL: 'https://pocket-api.sentinelayer.com',
  SENTI_API_BASE_URL: 'https://api.sentinelayer.com',
};
const FULL_DEPS = { dynamoClient: {}, signingKey: generateKeyPairSync('ed25519').privateKey, knownSessionIdsFor: async () => [], fetch: async () => ({ ok: true, status: 200, text: async () => '{}' }) };

test('createProdGateway FAILS BOOT on any missing production binding', () => {
  assert.throws(() => createProdGateway({}, FULL_DEPS), /prod config missing/);
  for (const k of Object.keys(FULL_ENV)) {
    const env = { ...FULL_ENV }; delete env[k];
    assert.throws(() => createProdGateway(env, FULL_DEPS), /prod config missing/, 'missing ' + k + ' must fail boot');
  }
});

test('createProdGateway FAILS BOOT on missing/empty deps', () => {
  assert.throws(() => createProdGateway(FULL_ENV, {}), /prod deps missing/);
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, dynamoClient: undefined }), /prod deps missing/, 'missing dynamoClient fails boot');
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, knownSessionIdsFor: undefined }), /prod deps missing/);
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: undefined }), /prod deps missing/, 'missing fetch fails boot (human-write client needs it)');
});

// Regression guard for the prod humanMessage `undefined dep -> TypeError` gap: the human-write client is a BOOT
// INVARIANT — boot cannot succeed without SENTI_API_BASE_URL + fetch, which are exactly what construct + wire it.
test('createProdGateway REQUIRES the human-write config so deps.postHumanMessage is never undefined', () => {
  const noBase = { ...FULL_ENV }; delete noBase.SENTI_API_BASE_URL;
  assert.throws(() => createProdGateway(noBase, FULL_DEPS), /prod config missing: SENTI_API_BASE_URL/);
  assert.throws(() => createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: undefined }), /prod deps missing/);
  assert.equal(typeof createProdGateway(FULL_ENV, FULL_DEPS).handle, 'function'); // both present => boots => client wired
});

test('createProdGateway + createLambda boot with complete config', () => {
  const gw = createProdGateway(FULL_ENV, FULL_DEPS);
  assert.equal(typeof gw.handle, 'function');
  assert.equal(typeof createLambda(FULL_ENV, FULL_DEPS), 'function');
});

// DIAL-ME prod wiring: a valid session must reach /dial* (pocket:dial in the verifier's granted set), the device binds
// under the VERIFIED identity, and /dial rings via deps.apnsSend — else honestly 501.
const dialFetch = (id = 'u1') => async (url) => (String(url).includes('/auth/me')
  ? { ok: true, status: 200, json: async () => ({ id }) }
  : { ok: true, status: 200, json: async () => ({}), text: async () => '{}' });

test('createProdGateway wires DIAL-ME: /dial/register binds under the VERIFIED humanId; /dial rings via apnsSend', async () => {
  const registered = [];
  const deviceRegistry = {
    async register(r) { registered.push(r); return { deviceCount: 1 }; },
    async lookup({ humanId, sessionId }) { return registered.filter((d) => d.humanId === humanId && d.sessionId === sessionId).map((d) => ({ voipToken: d.voipToken, platform: d.platform })); },
  };
  const apnsSent = [];
  const gw = createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: dialFetch(), knownSessionIdsFor: async () => ['sess-1'], deviceRegistry, apnsSend: async (a) => { apnsSent.push(a); return { delivered: true }; } });
  const reg = await gw.handle({ method: 'POST', path: '/dial/register', headers: { authorization: 'Bearer t' }, body: { voipToken: 'tok', sessionId: 'sess-1' } });
  assert.equal(reg.status, 200, 'a valid session reaches /dial/register (pocket:dial is granted)');
  assert.equal(registered[0].humanId, 'u1', 'device bound to the /auth/me identity, never the body');
  const dial = await gw.handle({ method: 'POST', path: '/dial', headers: { authorization: 'Bearer t' }, body: { message: 'ring', sessionId: 'sess-1' } });
  assert.equal(dial.status, 200);
  assert.equal(apnsSent[0].voipToken, 'tok', 'the registered token is resolved + rung');
});

test('createProdGateway: /dial honestly 501s without apnsSend, but /dial/register still records', async () => {
  const deviceRegistry = { async register() { return { deviceCount: 1 }; }, async lookup() { return []; } };
  const gw = createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: dialFetch(), knownSessionIdsFor: async () => ['sess-1'], deviceRegistry }); // NO apnsSend
  assert.equal((await gw.handle({ method: 'POST', path: '/dial/register', headers: { authorization: 'Bearer t' }, body: { voipToken: 'tok', sessionId: 'sess-1' } })).status, 200, 'register works before APNs is wired');
  const dial = await gw.handle({ method: 'POST', path: '/dial', headers: { authorization: 'Bearer t2' }, body: { message: 'ring', sessionId: 'sess-1' } });
  assert.equal(dial.status, 501, 'no apnsSend -> pushBackend undefined -> dial-not-configured');
});

test('createProdGateway wires /deck?format=video: honest 501 without the native backends, assembles with them injected', async () => {
  const deckBody = { deck: { slides: [{ template: 'title', content: { title: 'Hello' } }] }, format: 'video' };
  // no rasterize/encodeVideo forwarded -> honest 501 no-video-capability (never a fabricated video)
  const gwNo = createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: dialFetch() });
  assert.equal((await gwNo.handle({ method: 'POST', path: '/deck', headers: { authorization: 'Bearer t' }, body: deckBody })).status, 501);
  // deploy injects resvg/sharp + ffmpeg -> forwarded -> video assembles (binary mp4)
  const gwYes = createProdGateway(FULL_ENV, { ...FULL_DEPS, fetch: dialFetch(), rasterize: async () => Buffer.from('PNG'), encodeVideo: async () => ({ video: Buffer.from('MP4'), format: 'mp4' }) });
  const rVid = await gwYes.handle({ method: 'POST', path: '/deck', headers: { authorization: 'Bearer t2' }, body: deckBody });
  assert.equal(rVid.status, 200);
  assert.equal(rVid.headers['content-type'], 'video/mp4', 'the injected backend produced a real mp4 response');
});

test('createProdGateway env-constructs the native video backend ONLY behind the sandbox ack (SSRF/LFI fail-safe)', async () => {
  const deckBody = { deck: { slides: [{ template: 'title', content: { title: 'x' } }] }, format: 'video' };
  // binaries present but NO RESVG_EGRESS_SANDBOXED ack -> deckVideo NOT constructed -> 501 (never exec an unsandboxed resvg)
  const noAck = createProdGateway({ ...FULL_ENV, RESVG_BIN: '/nonexistent/resvg', FFMPEG_BIN: '/nonexistent/ffmpeg' }, { ...FULL_DEPS, fetch: dialFetch() });
  assert.equal((await noAck.handle({ method: 'POST', path: '/deck', headers: { authorization: 'Bearer t' }, body: deckBody })).status, 501, 'no sandbox ack -> video stays off (fail-safe)');
  // binaries + explicit ack -> deckVideo IS constructed + wired -> it ATTEMPTS assembly (the fake binary fails at exec ->
  // raster-failed -> 502, NOT 501) — which distinguishes "wired but binary-failed" from "not wired", proving the wiring.
  const acked = createProdGateway({ ...FULL_ENV, RESVG_BIN: '/nonexistent/resvg', FFMPEG_BIN: '/nonexistent/ffmpeg', RESVG_EGRESS_SANDBOXED: '1' }, { ...FULL_DEPS, fetch: dialFetch() });
  assert.equal((await acked.handle({ method: 'POST', path: '/deck', headers: { authorization: 'Bearer t2' }, body: deckBody })).status, 502, 'acked -> deckVideo wired -> attempts assembly -> fake binary -> 502 (not 501)');
});

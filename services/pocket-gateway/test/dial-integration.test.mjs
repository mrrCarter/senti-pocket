// dial-integration.test.mjs — the FULL DIAL-ME wire through createGateway(): /dial/register (relay) populates the
// device registry that POST /dial (warden) resolves via the registry-backed pushBackend (relay). Proves the split
// works TOGETHER end-to-end AND that the humanId isolation holds through the real handler boundary — a caller can only
// ring a device THEY registered, keyed by the VERIFIED token. Hermetic: in-mem registry + fake apnsSend + injected now.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createGateway } from '../src/handlers.mjs';
import { createDialPushBackend, computeDialId } from '../src/dial-registry.mjs';
import {
  DEVICE_REGISTRY_OWNER_VERSION,
  createInMemoryDeviceRegistryV2,
  deriveDeviceOwnerHandle,
} from '../src/device-registry-v2.mjs';

const NOW = 1_770_000_000_000;
const FULL = ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial'];
const V2_KEY = Buffer.alloc(32, 0x61);
const v2Principal = (humanId) => `pocket.principal.senti.v1\n${humanId.length}:${humanId}`;
const v2Owner = (humanId = 'u1') => ({
  ownerVersion: DEVICE_REGISTRY_OWNER_VERSION,
  ownerHandle: deriveDeviceOwnerHandle(V2_KEY, v2Principal(humanId), humanId),
});

function inMemRegistry() {
  const records = [];
  return {
    records,
    async register(r) { records.push(r); return { deviceCount: records.filter((x) => x.humanId === r.humanId && x.sessionId === r.sessionId).length }; },
    async lookup({ humanId, sessionId }) { return records.filter((x) => x.humanId === humanId && x.sessionId === sessionId).map((x) => ({ voipToken: x.voipToken, platform: x.platform })); },
  };
}

// Gateway wired EXACTLY as the deploy would: deps.deviceRegistry = the store, deps.pushBackend = the registry-backed
// impl. verifyToken derives humanId from the bearer so we can exercise two distinct callers.
function makeGateway({ scopes = FULL } = {}) {
  const deviceRegistry = inMemRegistry();
  const apnsSent = [];
  const gw = createGateway({
    verifyToken: async (h) => { const m = /Bearer (\w+)/.exec((h && h.authorization) || ''); return m ? { humanId: m[1], principal: m[1], scopes } : null; },
    knownSessionIdsFor: async () => ['sess-1'],
    deviceRegistry,
    pushBackend: createDialPushBackend({ deviceRegistry, apnsSend: async (a) => { apnsSent.push(a); return { delivered: true }; }, now: () => NOW }),
    run: () => '{}',       // benign; dial paths never author
    signingKey: {},
  });
  return { gw, deviceRegistry, apnsSent };
}
const call = (gw, path, body, token = 'u1') => gw.handle({ method: 'POST', path, headers: { authorization: `Bearer ${token}` }, body });
const parse = (r) => (typeof r.body === 'string' ? JSON.parse(r.body) : r.body);

function makeV2Gateway({
  now = () => NOW,
  leaseSeconds,
  scopesFor = () => FULL,
  knownSessionIdsFor = async () => ['sess-1'],
  identityForToken = (token) => token,
} = {}) {
  const deviceRegistry = createInMemoryDeviceRegistryV2({
    hmacKey: V2_KEY,
    now,
    ...(leaseSeconds === undefined ? {} : { leaseSeconds }),
  });
  const apnsSent = [];
  const gw = createGateway({
    verifyToken: async (headers) => {
      const match = /Bearer (\w+)/.exec(headers?.authorization || '');
      const humanId = match ? identityForToken(match[1]) : undefined;
      return match ? {
        humanId,
        principal: v2Principal(humanId),
        scopes: scopesFor(humanId),
      } : null;
    },
    knownSessionIdsFor,
    now: () => new Date(now()).toISOString(),
    deviceRegistry,
    pushBackend: createDialPushBackend({
      deviceRegistry,
      apnsSend: async (input) => { apnsSent.push(input); return { delivered: true }; },
      now,
    }),
    run: () => '{}',
    signingKey: {},
  });
  return { gw, deviceRegistry, apnsSent };
}

const v2Body = (idempotencyKey, token = 'v2-token', humanId = 'u1') => ({
  registrationVersion: 2,
  ...v2Owner(humanId),
  installationId: Buffer.alloc(32, 0x62).toString('base64url'),
  idempotencyKey,
  voipToken: token,
  sessionId: 'sess-1',
  platform: 'apns',
});
const v2DeniedReceipt = (body, error) => ({
  registered: false,
  committed: false,
  authorized: false,
  revocationRequired: false,
  reason: 'registration-denied-before-commit',
  error,
  registrationVersion: body.registrationVersion,
  ownerVersion: body.ownerVersion,
  ownerHandle: body.ownerHandle,
  sessionId: body.sessionId,
  platform: body.platform,
  idempotent: true,
});
const v2CleanupBody = (idempotencyKey, token = 'v2-token', humanId = 'u1') => {
  const source = v2Body(idempotencyKey, token, humanId);
  return {
    registrationVersion: source.registrationVersion,
    ownerVersion: source.ownerVersion,
    ownerHandle: source.ownerHandle,
    installationId: source.installationId,
    idempotencyKey: source.idempotencyKey,
    tokenDigest: createHash('sha256').update(source.voipToken, 'utf8').digest('base64url'),
    sessionId: source.sessionId,
    platform: source.platform,
  };
};
const v2UnregisterBody = (source, registration) => ({
  registrationVersion: source.registrationVersion,
  ownerVersion: source.ownerVersion,
  ownerHandle: source.ownerHandle,
  installationId: source.installationId,
  sessionId: source.sessionId,
  bindingId: registration.bindingId,
  bindingRevision: registration.bindingRevision,
});

test('e2e: /dial before any device is registered -> 502 no-device-token (fail-closed, honest)', async () => {
  const { gw, apnsSent } = makeGateway();
  const res = await call(gw, '/dial', { message: 'ship?', sessionId: 'sess-1' });
  assert.equal(res.status, 502);
  assert.equal(parse(res).reason, 'no-device-token');
  assert.equal(apnsSent.length, 0);
});

test('e2e: register -> /dial resolves the token + rings it with the deterministic payload (the whole wire)', async () => {
  const { gw, deviceRegistry, apnsSent } = makeGateway();
  // 1) the phone registers its VoIP token (onVoipToken seam)
  const reg = await call(gw, '/dial/register', { voipToken: 'apns-tok-1', sessionId: 'sess-1' });
  assert.equal(reg.status, 200);
  assert.deepEqual(parse(reg), { registered: true, sessionId: 'sess-1', platform: 'apns', deviceCount: 1 });
  assert.equal(deviceRegistry.records[0].humanId, 'u1', 'device bound to the VERIFIED token humanId, not the body');
  // 2) /dial resolves that token via the registry-backed pushBackend + rings it
  const res = await call(gw, '/dial', { message: 'Two shipped; one blocker. GO?', sessionId: 'sess-1', priority: 'high' });
  assert.equal(res.status, 200);
  assert.equal(parse(res).dispatched, true);
  assert.equal(parse(res).dialId, computeDialId('u1', 'sess-1', 'Two shipped; one blocker. GO?', NOW), 'dialId deterministic + consistent across the wire');
  // the APNs send got the resolved token + the deterministic forge-decode payload
  assert.equal(apnsSent.length, 1);
  assert.equal(apnsSent[0].voipToken, 'apns-tok-1');
  assert.equal(apnsSent[0].payload.id, parse(res).dialId);
  assert.equal(apnsSent[0].payload.message, 'Two shipped; one blocker. GO?');
  assert.equal(apnsSent[0].payload.priority, 'high');
  assert.equal(apnsSent[0].payload.sessionId, 'sess-1');
});

test('e2e ISOLATION: a caller rings only THEIR OWN device — u2 cannot ring u1 device for the same session', async () => {
  const { gw, apnsSent } = makeGateway();
  await call(gw, '/dial/register', { voipToken: 'u1-device', sessionId: 'sess-1' }, 'u1'); // u1 registers
  // u2 is ALSO a sess-1 member (passes membership) but the dispatch resolves for (u2, sess-1) = NO device -> 502.
  // u1's device is NEVER rung: dispatch is keyed by the VERIFIED humanId, not just session membership.
  const res = await call(gw, '/dial', { message: 'ring', sessionId: 'sess-1' }, 'u2');
  assert.equal(res.status, 502);
  assert.equal(parse(res).reason, 'no-device-token');
  assert.equal(apnsSent.length, 0, "u1's device was never rung by u2 — humanId isolation holds through the boundary");
});

test('e2e: /dial/register is membership + scope + auth gated', async () => {
  const { gw } = makeGateway();
  assert.equal((await call(gw, '/dial/register', { voipToken: 't', sessionId: 'other-sess' })).status, 403, 'non-member session');
  assert.equal((await call(gw, '/dial/register', { sessionId: 'sess-1' })).status, 400, 'missing voipToken');
  const { gw: noScope } = makeGateway({ scopes: ['sessions:read', 'sessions:write'] });
  assert.equal((await call(noScope, '/dial/register', { voipToken: 't', sessionId: 'sess-1' })).status, 403, 'missing pocket:dial');
  assert.equal((await gw.handle({ method: 'POST', path: '/dial/register', headers: {}, body: { voipToken: 't', sessionId: 'sess-1' } })).status, 401, 'no token');
});

test('e2e: /dial/register fail-closed when no deviceRegistry is wired -> 501', async () => {
  const gw = createGateway({
    verifyToken: async () => ({ humanId: 'u1', principal: 'u1', scopes: FULL }),
    knownSessionIdsFor: async () => ['sess-1'],
    run: () => '{}', signingKey: {},
    // no deviceRegistry, no pushBackend
  });
  const res = await gw.handle({ method: 'POST', path: '/dial/register', headers: { authorization: 'Bearer u1' }, body: { voipToken: 't', sessionId: 'sess-1' } });
  assert.equal(res.status, 501);
  assert.equal(parse(res).reason, 'dial-not-configured');
});

test('V2 e2e: registration context is auth-only, stable across bearer rotation, and never cacheable', async () => {
  let membershipCalls = 0;
  const { gw } = makeV2Gateway({
    scopesFor: () => [],
    identityForToken: () => 'u1',
    knownSessionIdsFor: async () => { membershipCalls += 1; return []; },
  });
  const request = (authorization) =>
    gw.handle({
      method: 'GET',
      path: '/dial/register/context',
      headers: authorization ? { authorization } : {},
    });
  const first = await request('Bearer rotated1');
  const second = await request('Bearer rotated2');
  const expected = {
    registrationVersion: 2,
    ...v2Owner(),
    serverTime: new Date(NOW).toISOString(),
  };
  assert.equal(first.status, 200);
  assert.deepEqual(parse(first), expected);
  assert.deepEqual(parse(second), expected);
  assert.equal(first.headers['cache-control'], 'no-store');
  assert.equal(first.headers.pragma, 'no-cache');
  assert.equal(membershipCalls, 0, 'context needs neither scope nor session membership');

  const unauthenticated = await request();
  assert.equal(unauthenticated.status, 401);
  assert.equal(unauthenticated.headers['cache-control'], 'no-store');
  assert.equal(unauthenticated.headers.pragma, 'no-cache');

  const failedContextRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    async registrationContext() { throw new Error('unavailable'); },
    async register() { throw new Error('unused'); },
    async reconcileRegistration() { return null; },
    async denyRegistration() { return { state: 'denied', ...v2Owner() }; },
    async unregister() { return { removed: false, ...v2Owner() }; },
    async lookup() { return []; },
  };
  const failedGateway = createGateway({
    verifyToken: async () => ({ humanId: 'u1', principal: v2Principal('u1'), scopes: [] }),
    knownSessionIdsFor: async () => [],
    now: () => new Date(NOW).toISOString(),
    deviceRegistry: failedContextRegistry,
    run: () => '{}',
    signingKey: {},
  });
  const failed = await failedGateway.handle({ method: 'GET', path: '/dial/register/context', headers: {} });
  assert.equal(failed.status, 502);
  assert.equal(failed.headers['cache-control'], 'no-store');
  assert.equal(failed.headers.pragma, 'no-cache');
});

test('V2 e2e: a stable owner prevents principal A -> B rebinding and cross-owner unregister', async () => {
  const { gw, apnsSent } = makeV2Gateway();
  const first = await call(
    gw,
    '/dial/register',
    v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'token-a'),
    'u1',
  );
  assert.equal(first.status, 200);
  const bindingA = parse(first);

  const ringA = await call(gw, '/dial', { message: 'A?', sessionId: 'sess-1' }, 'u1');
  assert.equal(ringA.status, 200);
  assert.equal(apnsSent.at(-1).payload.v, 2);
  assert.deepEqual(apnsSent.at(-1).payload.binding, {
    v: 2,
    id: bindingA.bindingId,
    revision: 1,
  });

  const second = await call(
    gw,
    '/dial/register',
    {
      ...v2Body('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'token-b'),
      ...v2Owner('u2'),
      expectedBindingId: bindingA.bindingId,
      expectedBindingRevision: bindingA.bindingRevision,
    },
    'u2',
  );
  assert.equal(second.status, 409);
  assert.deepEqual(parse(second), {
    error: 'registry owner does not match authenticated principal',
    reason: 'registry-owner-conflict',
  });

  const crossOwnerDelete = await gw.handle({
    method: 'DELETE',
    path: '/dial/register',
    headers: { authorization: 'Bearer u2' },
    body: v2UnregisterBody(v2Body('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'token-b', 'u2'), bindingA),
  });
  assert.equal(crossOwnerDelete.status, 409);
  assert.equal(parse(crossOwnerDelete).reason, 'registry-owner-conflict');

  const retainedA = await call(gw, '/dial', { message: 'still A?', sessionId: 'sess-1' }, 'u1');
  assert.equal(retainedA.status, 200);
  assert.equal(apnsSent.at(-1).voipToken, 'token-a');
  assert.deepEqual(apnsSent.at(-1).payload.binding, {
    v: 2,
    id: bindingA.bindingId,
    revision: bindingA.bindingRevision,
  });
  assert.equal((await call(gw, '/dial', { message: 'B?', sessionId: 'sess-1' }, 'u2')).status, 502);
});

test('V2 e2e: exact current unregister needs neither scope nor membership and performs no membership lookup', async () => {
  let scopes = FULL;
  let sessions = ['sess-1'];
  let membershipCalls = 0;
  const { gw, deviceRegistry } = makeV2Gateway({
    scopesFor: () => scopes,
    knownSessionIdsFor: async () => {
      membershipCalls += 1;
      return sessions;
    },
  });
  const body = v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const registered = parse(await call(gw, '/dial/register', body, 'u1'));
  assert.equal(membershipCalls, 1);
  scopes = [];
  sessions = [];
  const beforeDeleteMembershipCalls = membershipCalls;
  const response = await gw.handle({
    method: 'DELETE',
    path: '/dial/register',
    headers: { authorization: 'Bearer u1' },
    body: v2UnregisterBody(body, registered),
  });
  assert.equal(response.status, 200);
  assert.equal(membershipCalls, beforeDeleteMembershipCalls, 'DELETE bypasses membership by design');
  assert.deepEqual(
    await deviceRegistry.lookup({
      principal: 'pocket.principal.senti.v1\n2:u1',
      humanId: 'u1',
      sessionId: body.sessionId,
    }),
    [],
  );
});

test('V2 e2e: digest-only cleanup requires auth but no scope/membership and removes the exact committed route', async () => {
  let scopes = FULL;
  let sessions = ['sess-1'];
  let membershipCalls = 0;
  const { gw, deviceRegistry } = makeV2Gateway({
    scopesFor: () => scopes,
    knownSessionIdsFor: async () => {
      membershipCalls += 1;
      return sessions;
    },
  });
  const idempotencyKey = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const registered = await call(gw, '/dial/register', v2Body(idempotencyKey), 'u1');
  assert.equal(registered.status, 200);
  assert.equal(membershipCalls, 1);

  scopes = [];
  sessions = [];
  const beforeCleanupMembershipCalls = membershipCalls;
  const cleanup = await call(gw, '/dial/register/reconcile', v2CleanupBody(idempotencyKey), 'u1');
  assert.equal(cleanup.status, 200);
  assert.deepEqual(parse(cleanup), {
    registrationVersion: 2,
    ...v2Owner(),
    idempotencyKey,
    sessionId: 'sess-1',
    platform: 'apns',
    registered: false,
    authorized: false,
    cleanupComplete: true,
    serverTime: new Date(NOW).toISOString(),
  });
  assert.equal(membershipCalls, beforeCleanupMembershipCalls, 'cleanup makes no membership call');
  assert.deepEqual(
    await deviceRegistry.lookup({
      principal: 'pocket.principal.senti.v1\n2:u1',
      humanId: 'u1',
      sessionId: 'sess-1',
    }),
    [],
  );
  assert.equal((await call(gw, '/dial/register/reconcile', v2CleanupBody(idempotencyKey), 'u1')).status, 200);
  assert.equal(
    (
      await gw.handle({
        method: 'POST',
        path: '/dial/register/reconcile',
        headers: {},
        body: v2CleanupBody(idempotencyKey),
      })
    ).status,
    401,
    'the subtractive endpoint still requires a verified bearer',
  );
});

test('V2 e2e: cleanup for A cannot erase newer same-intent operation B', async () => {
  let wallMs = NOW;
  const { gw, deviceRegistry } = makeV2Gateway({ now: () => wallMs, leaseSeconds: 60 });
  const aKey = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const bKey = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const a = parse(await call(gw, '/dial/register', v2Body(aKey), 'u1'));

  wallMs += 10_000;
  const bResponse = await call(gw, '/dial/register', {
    ...v2Body(bKey),
    expectedBindingId: a.bindingId,
    expectedBindingRevision: a.bindingRevision,
  }, 'u1');
  assert.equal(bResponse.status, 200);
  const b = parse(bResponse);
  assert.equal(b.bindingId, a.bindingId);
  assert.equal(b.bindingRevision, a.bindingRevision + 1);

  assert.equal((await call(gw, '/dial/register/reconcile', v2CleanupBody(aKey), 'u1')).status, 200);
  assert.deepEqual(
    (await deviceRegistry.lookup({
      principal: 'pocket.principal.senti.v1\n2:u1',
      humanId: 'u1',
      sessionId: 'sess-1',
    })).map(({ bindingRevision }) => bindingRevision),
    [b.bindingRevision],
    'the handler-level digest cleanup retains B because its operation revision is newer',
  );

  assert.equal((await call(gw, '/dial/register/reconcile', v2CleanupBody(bKey), 'u1')).status, 200);
  assert.deepEqual(
    await deviceRegistry.lookup({
      principal: 'pocket.principal.senti.v1\n2:u1',
      humanId: 'u1',
      sessionId: 'sess-1',
    }),
    [],
  );
});

test('V2 e2e: cleanup is principal-isolated and rejects a raw-token/unknown-field body', async () => {
  const { gw, deviceRegistry } = makeV2Gateway();
  const idempotencyKey = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  assert.equal((await call(gw, '/dial/register', v2Body(idempotencyKey), 'u1')).status, 200);

  const otherPrincipal = await call(gw, '/dial/register/reconcile', v2CleanupBody(idempotencyKey, 'v2-token', 'u2'), 'u2');
  assert.equal(otherPrincipal.status, 409, 'an active installation is protected by its stable owner fence');
  assert.deepEqual(parse(otherPrincipal), {
    error: 'registry owner does not match authenticated principal',
    reason: 'registry-owner-conflict',
  });
  assert.equal(
    (
      await deviceRegistry.lookup({
        principal: 'pocket.principal.senti.v1\n2:u1',
        humanId: 'u1',
        sessionId: 'sess-1',
      })
    ).length,
    1,
    'another principal cannot delete the owner route',
  );

  const invalid = await call(
    gw,
    '/dial/register/reconcile',
    { ...v2CleanupBody(idempotencyKey), voipToken: 'raw-token-is-not-part-of-cleanup' },
    'u1',
  );
  assert.equal(invalid.status, 400);
  assert.equal(parse(invalid).reason, 'registration-cleanup-v2-required');
});

test('V2 e2e: missing scope can recover only revocation fences for an exact commit, then delete it', async () => {
  let scopes = FULL;
  let sessions = ['sess-1'];
  let membershipCalls = 0;
  const { gw, deviceRegistry } = makeV2Gateway({
    scopesFor: () => scopes,
    knownSessionIdsFor: async () => { membershipCalls += 1; return sessions; },
  });
  const body = v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const first = parse(await call(gw, '/dial/register', body, 'u1'));
  const originalBinding = structuredClone([...deviceRegistry._records.values()][0]);

  scopes = ['sessions:read', 'sessions:write'];
  sessions = [];
  membershipCalls = 0;
  const replayResponse = await call(gw, '/dial/register', body, 'u1');
  const replay = parse(replayResponse);
  assert.equal(replayResponse.status, 409);
  assert.equal(replay.reason, 'registration-committed-but-unauthorized');
  assert.equal(replay.registered, false);
  assert.equal(replay.committed, true);
  assert.equal(replay.authorized, false);
  assert.equal(replay.revocationRequired, true);
  assert.equal(replay.bindingId, first.bindingId);
  assert.equal(replay.bindingRevision, first.bindingRevision);
  assert.equal(replay.tokenClaimId, first.tokenClaimId);
  assert.equal(replay.tokenClaimRevision, first.tokenClaimRevision);
  assert.equal(replay.expiresAt, first.expiresAt);
  assert.equal(membershipCalls, 0, 'missing scope is already non-authoritative; exact recovery performs no membership read');
  assert.deepEqual([...deviceRegistry._records.values()][0], originalBinding, 'recovery never renews the lease');

  const changed = await call(gw, '/dial/register', { ...body, voipToken: 'changed-token' }, 'u1');
  assert.deepEqual(parse(changed), { error: 'missing scope pocket:dial' });
  assert.equal(changed.status, 403, 'a changed request receives no committed-state oracle');

  const deleted = await gw.handle({
    method: 'DELETE',
    path: '/dial/register',
    headers: { authorization: 'Bearer u1' },
    body: v2UnregisterBody(body, replay),
  });
  assert.equal(deleted.status, 200, 'authenticated exact revocation remains available after the scope grant disappears');
  assert.deepEqual(
    await deviceRegistry.lookup({
      principal: 'pocket.principal.senti.v1\n2:u1',
      humanId: 'u1',
      sessionId: body.sessionId,
    }),
    [],
  );
});

test('V2 e2e race: a definitive missing-scope 403 cannot be followed by the held registration committing', async () => {
  const backing = createInMemoryDeviceRegistryV2({ hmacKey: Buffer.alloc(32, 0x61), now: () => NOW });
  let markCommitReached;
  let releaseCommit;
  const commitReached = new Promise((resolve) => {
    markCommitReached = resolve;
  });
  const commitRelease = new Promise((resolve) => {
    releaseCommit = resolve;
  });
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    registrationContext: (args) => backing.registrationContext(args),
    reconcileRegistration: (args) => backing.reconcileRegistration(args),
    denyRegistration: (args) => backing.denyRegistration(args),
    unregister: (args) => backing.unregister(args),
    lookup: (args) => backing.lookup(args),
    async register(args) {
      markCommitReached();
      await commitRelease;
      return backing.register(args);
    },
  };
  let scopes = FULL;
  const gw = createGateway({
    verifyToken: async () => ({
      humanId: 'u1',
      principal: 'pocket.principal.senti.v1\n2:u1',
      scopes,
    }),
    knownSessionIdsFor: async () => ['sess-1'],
    now: () => new Date(NOW).toISOString(),
    deviceRegistry,
    run: () => '{}',
    signingKey: {},
  });
  const body = v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const original = call(gw, '/dial/register', body, 'u1');
  await commitReached;
  scopes = ['sessions:read'];
  const retry = await call(gw, '/dial/register', body, 'u1');
  assert.equal(retry.status, 403, 'denial barrier linearized before the held commit');
  assert.deepEqual(parse(retry), v2DeniedReceipt(body, 'missing scope pocket:dial'));
  assert.deepEqual(
    await backing.lookup({ principal: 'pocket.principal.senti.v1\n2:u1', humanId: 'u1', sessionId: 'sess-1' }),
    [],
  );
  releaseCommit();
  const originalResponse = await original;
  assert.equal(originalResponse.status, 409);
  assert.equal(parse(originalResponse).reason, 'registration-denied-before-commit');
  assert.deepEqual(
    await backing.lookup({ principal: 'pocket.principal.senti.v1\n2:u1', humanId: 'u1', sessionId: 'sess-1' }),
    [],
    'the original transaction cannot create a route after the 403',
  );
});

test('V2 e2e race: commit-first makes the missing-scope retry return exact revocation fences, never 403', async () => {
  const backing = createInMemoryDeviceRegistryV2({ hmacKey: Buffer.alloc(32, 0x61), now: () => NOW });
  let markCommitReached;
  let releaseResponse;
  const commitReached = new Promise((resolve) => {
    markCommitReached = resolve;
  });
  const responseRelease = new Promise((resolve) => {
    releaseResponse = resolve;
  });
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    registrationContext: (args) => backing.registrationContext(args),
    reconcileRegistration: (args) => backing.reconcileRegistration(args),
    denyRegistration: (args) => backing.denyRegistration(args),
    unregister: (args) => backing.unregister(args),
    lookup: (args) => backing.lookup(args),
    async register(args) {
      const result = await backing.register(args);
      markCommitReached();
      await responseRelease;
      return result;
    },
  };
  let scopes = FULL;
  const gw = createGateway({
    verifyToken: async () => ({
      humanId: 'u1',
      principal: 'pocket.principal.senti.v1\n2:u1',
      scopes,
    }),
    knownSessionIdsFor: async () => ['sess-1'],
    now: () => new Date(NOW).toISOString(),
    deviceRegistry,
    run: () => '{}',
    signingKey: {},
  });
  const body = v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const original = call(gw, '/dial/register', body, 'u1');
  await commitReached;
  scopes = ['sessions:read'];
  const retry = await call(gw, '/dial/register', body, 'u1');
  assert.equal(retry.status, 409);
  assert.equal(parse(retry).reason, 'registration-committed-but-unauthorized');
  assert.equal(parse(retry).committed, true);
  releaseResponse();
  const originalResponse = await original;
  assert.equal(originalResponse.status, 200);
  assert.equal(parse(retry).bindingId, parse(originalResponse).bindingId);
  assert.equal(parse(retry).tokenClaimId, parse(originalResponse).tokenClaimId);
});

test('V2 e2e membership race: a definitive 403 barriers the held registration commit', async () => {
  const backing = createInMemoryDeviceRegistryV2({ hmacKey: Buffer.alloc(32, 0x61), now: () => NOW });
  let markCommitReached;
  let releaseCommit;
  const commitReached = new Promise((resolve) => { markCommitReached = resolve; });
  const commitRelease = new Promise((resolve) => { releaseCommit = resolve; });
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    registrationContext: (args) => backing.registrationContext(args),
    reconcileRegistration: (args) => backing.reconcileRegistration(args),
    denyRegistration: (args) => backing.denyRegistration(args),
    unregister: (args) => backing.unregister(args),
    lookup: (args) => backing.lookup(args),
    async register(args) {
      markCommitReached();
      await commitRelease;
      return backing.register(args);
    },
  };
  let member = true;
  const gw = createGateway({
    verifyToken: async () => ({
      humanId: 'u1',
      principal: 'pocket.principal.senti.v1\n2:u1',
      scopes: FULL,
    }),
    knownSessionIdsFor: async () => (member ? ['sess-1'] : []),
    now: () => new Date(NOW).toISOString(),
    deviceRegistry,
    run: () => '{}',
    signingKey: {},
  });
  const body = v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const original = call(gw, '/dial/register', body, 'u1');
  await commitReached;
  member = false;
  const retry = await call(gw, '/dial/register', body, 'u1');
  assert.equal(retry.status, 403);
  assert.deepEqual(parse(retry), v2DeniedReceipt(body, 'not a known session for this user'));
  releaseCommit();
  const originalResponse = await original;
  assert.equal(originalResponse.status, 409);
  assert.equal(parse(originalResponse).reason, 'registration-denied-before-commit');
  assert.deepEqual(
    await backing.lookup({ principal: 'pocket.principal.senti.v1\n2:u1', humanId: 'u1', sessionId: 'sess-1' }),
    [],
  );
});

test('V2 e2e membership race: commit-first returns revocation fences instead of 403', async () => {
  const backing = createInMemoryDeviceRegistryV2({ hmacKey: Buffer.alloc(32, 0x61), now: () => NOW });
  let markCommitReached;
  let releaseResponse;
  const commitReached = new Promise((resolve) => { markCommitReached = resolve; });
  const responseRelease = new Promise((resolve) => { releaseResponse = resolve; });
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    registrationContext: (args) => backing.registrationContext(args),
    reconcileRegistration: (args) => backing.reconcileRegistration(args),
    denyRegistration: (args) => backing.denyRegistration(args),
    unregister: (args) => backing.unregister(args),
    lookup: (args) => backing.lookup(args),
    async register(args) {
      const result = await backing.register(args);
      markCommitReached();
      await responseRelease;
      return result;
    },
  };
  let member = true;
  const gw = createGateway({
    verifyToken: async () => ({
      humanId: 'u1',
      principal: 'pocket.principal.senti.v1\n2:u1',
      scopes: FULL,
    }),
    knownSessionIdsFor: async () => (member ? ['sess-1'] : []),
    now: () => new Date(NOW).toISOString(),
    deviceRegistry,
    run: () => '{}',
    signingKey: {},
  });
  const body = v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  const original = call(gw, '/dial/register', body, 'u1');
  await commitReached;
  member = false;
  const retry = await call(gw, '/dial/register', body, 'u1');
  assert.equal(retry.status, 409);
  assert.equal(parse(retry).reason, 'registration-committed-but-unauthorized');
  assert.equal(parse(retry).committed, true);
  releaseResponse();
  const originalResponse = await original;
  assert.equal(originalResponse.status, 200);
  assert.equal(parse(retry).bindingId, parse(originalResponse).bindingId);
  assert.equal(parse(retry).tokenClaimId, parse(originalResponse).tokenClaimId);
});

test('V2 e2e: missing-scope denial failures are retryable 502, not a definitive 403 miss', async () => {
  let membershipCalls = 0;
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    async registrationContext() { return { registrationVersion: 2, ...v2Owner() }; },
    async denyRegistration() { throw new Error('Dynamo unavailable'); },
    async reconcileRegistration() { throw new Error('must not read around denial'); },
    async register() { throw new Error('must not write'); },
    async unregister() { return { removed: false }; },
    async lookup() { return []; },
  };
  const gw = createGateway({
    verifyToken: async () => ({
      humanId: 'u1',
      principal: 'pocket.principal.senti.v1\n2:u1',
      scopes: ['sessions:read', 'sessions:write'],
    }),
    knownSessionIdsFor: async () => { membershipCalls += 1; return []; },
    deviceRegistry,
    run: () => '{}',
    signingKey: {},
  });
  const response = await call(
    gw,
    '/dial/register',
    v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    'u1',
  );
  assert.equal(response.status, 502);
  assert.deepEqual(parse(response), {
    error: 'registry denial failed',
    reason: 'registry-denial-failed',
  });
  assert.equal(membershipCalls, 0);
});

test('V2 e2e: an invalid shared clock fails before registration or cleanup mutation', async () => {
  let registryCalls = 0;
  const deviceRegistry = {
    protocolVersion: 2,
    operationOutcomeVersion: 1,
    async registrationContext() { return { registrationVersion: 2, ...v2Owner() }; },
    async register() { registryCalls += 1; throw new Error('must not write'); },
    async reconcileRegistration() { registryCalls += 1; return null; },
    async denyRegistration() { registryCalls += 1; return { state: 'denied' }; },
    async unregister() { registryCalls += 1; return { removed: false }; },
    async lookup() { return []; },
  };
  const gw = createGateway({
    verifyToken: async () => ({
      humanId: 'u1',
      principal: 'pocket.principal.senti.v1\n2:u1',
      scopes: FULL,
    }),
    knownSessionIdsFor: async () => ['sess-1'],
    now: () => 'not-an-instant',
    deviceRegistry,
    run: () => '{}',
    signingKey: {},
  });
  assert.equal((await call(
    gw,
    '/dial/register',
    v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    'u1',
  )).status, 500);
  assert.equal((await call(
    gw,
    '/dial/register/reconcile',
    v2CleanupBody('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    'u1',
  )).status, 500);
  assert.equal(registryCalls, 0);
});

test('V2 e2e: logical lease expiry returns no-device-token and never reaches APNs during reclaim grace', async () => {
  let wallMs = NOW;
  const { gw, apnsSent } = makeV2Gateway({
    now: () => wallMs,
    leaseSeconds: 60,
  });
  const registered = parse(await call(
    gw,
    '/dial/register',
    v2Body('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
    'u1',
  ));
  wallMs = Date.parse(registered.expiresAt);
  const response = await call(gw, '/dial', { message: 'expired?', sessionId: 'sess-1' }, 'u1');
  assert.equal(response.status, 502);
  assert.equal(parse(response).reason, 'no-device-token');
  assert.equal(apnsSent.length, 0);
});

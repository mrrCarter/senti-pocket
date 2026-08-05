// handlers-membership.test.mjs — exact target+bearer threading and role-aware route authorization.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway, storeKey } from '../src/handlers.mjs';
import { createInMemoryStore } from '../src/store.mjs';
import { computeProposalHash } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';
import {
  SentiTargetMembershipCredentialRejectedError,
  SentiTargetMembershipInvalidTargetError,
  SentiTargetMembershipRateLimitedError,
  SentiTargetMembershipUnavailableError,
} from '../src/senti-target-membership.mjs';

const SESSION = 'session-target-1';
const AUTHORIZATION = 'Bearer pocket-token';
const PRINCIPAL = 'pocket.principal.senti.v1\n8:user-123';
const { privateKey: SIGNING_KEY } = generateSigningKeypair();

const identity = Object.freeze({
  humanId: 'user-123',
  principal: PRINCIPAL,
  scopes: Object.freeze(['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial']),
});

const validProposal = (overrides = {}) => {
  const proposal = {
    id: 'proposal-1',
    kind: 'threadedReply',
    targetSessionId: SESSION,
    targetSequence: 12,
    renderedPreview: 'Approved.',
    requiresConfirmation: true,
    createdAt: '2026-08-05T11:00:00Z',
    sourceQuestionId: null,
    ...overrides,
  };
  proposal.proposalHash = computeProposalHash(proposal);
  return proposal;
};

const baseDeps = (overrides = {}) => ({
  verifyToken: async () => identity,
  store: createInMemoryStore(),
  run: () => '{}',
  signingKey: SIGNING_KEY,
  signingKeyId: 'test-key',
  reason: async () => ({ text: '', evidenceIds: [] }),
  brief: async () => ({ segments: [] }),
  pushBackend: async () => ({ dispatched: true, dialId: 'dial-1' }),
  deviceRegistry: { async register() { return { deviceCount: 1 }; }, async lookup() { return []; } },
  dialSignalStore: { async get() { return { id: 'dial-1', context: { sessionId: SESSION } }; } },
  now: () => '2026-08-05T11:02:00Z',
  ...overrides,
});

const routeCases = [
  {
    name: 'GET /checkpoint',
    target: SESSION,
    request: { method: 'GET', path: '/checkpoint', query: { sessionId: SESSION }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'POST /answer',
    target: SESSION,
    request: { method: 'POST', path: '/answer', body: { sessionId: SESSION, question: 'q' }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'POST /brief',
    target: SESSION,
    request: { method: 'POST', path: '/brief', body: { sessionId: SESSION }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'POST /actions/execute',
    target: SESSION,
    request: { method: 'POST', path: '/actions/execute', body: { proposal: { id: 'p', targetSessionId: SESSION } }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'POST /dial',
    target: SESSION,
    request: { method: 'POST', path: '/dial', body: { sessionId: SESSION, message: 'ring' }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'POST /dial/ring-owner',
    target: SESSION,
    request: { method: 'POST', path: '/dial/ring-owner', body: { question: 'Need input', context: { sessionId: SESSION } }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'POST /dial/register',
    target: SESSION,
    request: { method: 'POST', path: '/dial/register', body: { sessionId: SESSION, voipToken: 'abc123' }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 403,
  },
  {
    name: 'GET /dial hydration',
    target: SESSION,
    request: { method: 'GET', path: '/dial', query: { id: 'dial-1' }, headers: { authorization: AUTHORIZATION } },
    deniedStatus: 410,
  },
];

for (const scenario of routeCases) {
  test(`${scenario.name}: resolves exactly one target under the original bearer`, async () => {
    const calls = [];
    const gateway = createGateway(baseDeps({
      getTargetMembership: async (input) => { calls.push(input); return null; },
    }));
    const response = await gateway.handle(scenario.request);
    assert.equal(response.status, scenario.deniedStatus);
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0], { sessionId: scenario.target, authorization: AUTHORIZATION });
    assert.equal(Object.isFrozen(calls[0]), true, 'only a frozen minimized context crosses the adapter seam');
    if (scenario.name === 'GET /dial hydration') {
      assert.equal(response.headers['cache-control'], 'no-store');
      assert.equal(response.headers.pragma, 'no-cache');
    }
  });
}

test('legacy createGateway list seam remains source-compatible and receives minimized target context', async () => {
  const calls = [];
  const gateway = createGateway(baseDeps({
    getTargetMembership: undefined,
    knownSessionIdsFor: async (humanId, context) => { calls.push({ humanId, context }); return []; },
  }));
  const response = await gateway.handle(routeCases[0].request);
  assert.equal(response.status, 403);
  assert.deepEqual(calls, [{
    humanId: 'user-123',
    context: { sessionId: SESSION, authorization: AUTHORIZATION, access: 'member' },
  }]);
  assert.equal(Object.isFrozen(calls[0].context), true);
});

test('viewer cannot execute: denial occurs before durable reservation, runner, or post', async () => {
  const store = createInMemoryStore();
  let runnerCalls = 0;
  const proposal = validProposal();
  const gateway = createGateway(baseDeps({
    store,
    run: () => { runnerCalls += 1; return '{}'; },
    getTargetMembership: async ({ sessionId }) => Object.freeze({ sessionId, membershipRole: 'viewer' }),
  }));
  const response = await gateway.handle({
    method: 'POST', path: '/actions/execute', headers: { authorization: AUTHORIZATION },
    body: { proposal, confirmation: { proposalId: proposal.id, confirmedProposalHash: proposal.proposalHash, confirmedAt: '2026-08-05T11:01:00Z' } },
  });
  assert.equal(response.status, 403);
  assert.equal(runnerCalls, 0);
  assert.equal(await store.get(storeKey(PRINCIPAL, proposal.id)), undefined);
});

test('contributor passes execute membership policy and reaches proposal confirmation validation', async () => {
  const proposal = validProposal();
  const gateway = createGateway(baseDeps({
    getTargetMembership: async ({ sessionId }) => Object.freeze({ sessionId, membershipRole: 'contributor' }),
  }));
  const response = await gateway.handle({
    method: 'POST', path: '/actions/execute', headers: { authorization: AUTHORIZATION },
    body: { proposal, confirmation: { proposalId: proposal.id, confirmedProposalHash: 'sha256-wrong', confirmedAt: '2026-08-05T11:01:00Z' } },
  });
  assert.equal(response.status, 422, 'contributor gets past membership and is rejected by the later confirmation gate');
});

test('ring-owner requires contributor, while viewer may self-dial', async () => {
  let pushes = 0;
  let role = 'viewer';
  const gateway = createGateway(baseDeps({
    getTargetMembership: async ({ sessionId }) => Object.freeze({ sessionId, membershipRole: role }),
    pushBackend: async () => { pushes += 1; return { dispatched: true, dialId: 'dial-1' }; },
  }));
  const ringRequest = routeCases.find((item) => item.name.includes('ring-owner')).request;
  assert.equal((await gateway.handle(ringRequest)).status, 403);
  assert.equal(pushes, 0, 'viewer cannot trigger an agent-originated active notification');
  const dialRequest = routeCases.find((item) => item.name === 'POST /dial').request;
  assert.equal((await gateway.handle(dialRequest)).status, 200);
  assert.equal(pushes, 1, 'viewer may ring their own registered device');
  role = 'contributor';
  assert.equal((await gateway.handle(ringRequest)).status, 200);
  assert.equal(pushes, 2);
});

test('membership errors map to stable fail-closed gateway responses', async () => {
  const request = routeCases[0].request;
  for (const [error, status, retryAfter] of [
    [new SentiTargetMembershipCredentialRejectedError(), 401, undefined],
    [new SentiTargetMembershipRateLimitedError(17), 429, '17'],
    [new SentiTargetMembershipUnavailableError(), 503, undefined],
  ]) {
    const gateway = createGateway(baseDeps({ getTargetMembership: async () => { throw error; } }));
    const response = await gateway.handle(request);
    assert.equal(response.status, status);
    if (status === 503 || status === 429) assert.equal(response.body.retryable, true);
    assert.equal(response.headers['retry-after'], retryAfter);
  }
});

test('missing or ambiguous authorization never reaches the membership resolver', async () => {
  let calls = 0;
  const gateway = createGateway(baseDeps({ getTargetMembership: async () => { calls += 1; return null; } }));
  const missing = { ...routeCases[0].request, headers: {} };
  const ambiguous = { ...routeCases[0].request, headers: { authorization: AUTHORIZATION, Authorization: 'Bearer other' } };
  assert.equal((await gateway.handle(missing)).status, 401);
  assert.equal((await gateway.handle(ambiguous)).status, 401);
  assert.equal(calls, 0);
});

test('invalid execute target is rejected before a membership call', async () => {
  let calls = 0;
  const gateway = createGateway(baseDeps({ getTargetMembership: async () => { calls += 1; return null; } }));
  const response = await gateway.handle({
    method: 'POST', path: '/actions/execute', headers: { authorization: AUTHORIZATION },
    body: { proposal: { id: 'proposal-1', targetSessionId: '' } },
  });
  assert.equal(response.status, 403);
  assert.equal(calls, 0);
});

test('opaque dial lookup collapses every stored-target authorization failure to the absent-id 410', async () => {
  for (const error of [
    new SentiTargetMembershipInvalidTargetError(),
    new SentiTargetMembershipCredentialRejectedError(),
    new SentiTargetMembershipRateLimitedError(17),
    new SentiTargetMembershipUnavailableError(),
  ]) {
    const gateway = createGateway(baseDeps({
      dialSignalStore: { async get() { return { id: 'dial-1', context: { sessionId: '..' } }; } },
      getTargetMembership: async () => { throw error; },
    }));
    const response = await gateway.handle(routeCases.find((item) => item.name === 'GET /dial hydration').request);
    assert.equal(response.status, 410, error.code);
    assert.deepEqual(response.body, { error: 'dial signal unavailable', reason: 'gone' });
    assert.equal(response.headers['cache-control'], 'no-store');
    assert.equal(response.headers.pragma, 'no-cache');
  }
});

test('registration membership outage is retryable and performs no registry mutation', async () => {
  let registryCalls = 0;
  const gateway = createGateway(baseDeps({
    deviceRegistry: {
      async register() { registryCalls += 1; return { deviceCount: 1 }; },
      async lookup() { return []; },
    },
    getTargetMembership: async () => { throw new SentiTargetMembershipUnavailableError(); },
  }));
  const response = await gateway.handle(routeCases.find((item) => item.name === 'POST /dial/register').request);
  assert.equal(response.status, 503);
  assert.equal(response.body.retryable, true);
  assert.equal(registryCalls, 0);
});

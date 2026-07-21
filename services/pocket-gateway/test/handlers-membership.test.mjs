// handlers-membership.test.mjs — the read endpoints (/checkpoint /answer /brief) must scope membership by HUMANID, not
// the synthetic principal string. In prod ctx.principal = 'pocket.principal.senti.v1\n<humanId>', which never matches a
// humanId-keyed knownSessionIdsFor -> [] -> a valid member 403s. This asserts the ARG (existing tests ignore it).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';

const PRINCIPAL = 'pocket.principal.senti.v1\n8:user-123';

function gatewayRecordingMembership() {
  const calls = [];
  const gw = createGateway({
    verifyToken: async (h) => (h && h.authorization
      ? { humanId: 'user-123', principal: PRINCIPAL, scopes: ['sessions:read', 'pocket:voice'] }
      : null),
    signingKey: {}, // present so the endpoints pass the signing-config gate + reach the membership check
    reason: async () => ({ text: '', evidenceIds: [] }),   // present so /answer passes its 501 gate
    brief: async () => ({ segments: [] }),                  // present so /brief passes its 501 gate
    // membership is keyed by HUMANID; returns the session only when called with the humanId (NOT the principal string)
    knownSessionIdsFor: async (key) => { calls.push(key); return key === 'user-123' ? ['sess-1'] : []; },
  });
  return { gw, calls };
}

for (const path of ['/checkpoint', '/answer', '/brief']) {
  test(`${path}: membership scoped by humanId (not principal) — a valid member is NOT 403'd`, async () => {
    const { gw, calls } = gatewayRecordingMembership();
    const req = path === '/checkpoint'
      ? { method: 'GET', path, query: { sessionId: 'sess-1' }, headers: { authorization: 'Bearer t' } }
      : { method: 'POST', path, query: {}, headers: { authorization: 'Bearer t' }, body: { sessionId: 'sess-1', question: 'q' } };
    // downstream (checkpoint extraction / reasoning) may error without those deps — we only care that membership was
    // called with the humanId and did NOT 403. Guard the call so a downstream throw still lets us assert the arg.
    let res;
    try { res = await gw.handle(req); } catch { res = { status: 'threw-downstream' }; }
    assert.ok(calls.includes('user-123'), `${path} must call knownSessionIdsFor with the humanId`);
    assert.ok(!calls.includes(PRINCIPAL), `${path} must NOT call it with the synthetic principal string`);
    assert.notEqual(res.status, 403, `${path} must not 403 a valid member (the principal bug)`);
  });
}

test('sanity: a NON-member (unknown session) is still 403 (fix does not over-open)', async () => {
  const { gw } = gatewayRecordingMembership();
  const res = await gw.handle({ method: 'GET', path: '/checkpoint', query: { sessionId: 'sess-OTHER' }, headers: { authorization: 'Bearer t' } });
  assert.equal(res.status, 403); // humanId is known, but sess-OTHER is not in their session list
});

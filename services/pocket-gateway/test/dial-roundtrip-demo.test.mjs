// dial-roundtrip-demo.test.mjs — THE demonstrable artifact for Carter's multiplayer-AI demo beats 3+4, proven
// hermetically through the REAL createGateway() wire (no stubbed crypto — Warden's gate criteria).
//
// The demo narrative these tests pin, end-to-end at the gateway boundary:
//   BEAT 4 ("call user"): anyone in a senti session commands `sl ring-owner "<decision>"` -> Pocket rings the OWNER and
//     the ring carries WHO is asking ("this is claude-atlas" via callerName), the DECISION (question), the OPTIONS to
//     read aloud, and the sessionId+checkpointId the call is about. The ring TARGET is the verified caller's OWN human
//     (confused-deputy-safe: an agent cannot ring anyone else's phone; requestedBy is a DISPLAY label only).
//   BEAT 3 (answer -> same session): the owner answers on the call; the reply-back writes to the SAME senti session the
//     ring carried, via the REAL governed humanMessage path — confirmation-hash-bound, ed25519-signed receipt, authored
//     as human-mrrcarter, idempotent (a retry never double-writes).
//
// The ROUND-TRIP invariant (the thing the demo shows): the sessionId that leaves on the ring === the sessionId the
// answer writes back to. Proven below by capturing the ring's sessionId and asserting the governed write targets it.
//
// Fully hermetic: injected verifyToken / pushBackend / postHumanMessage(api) / sl runner / signing key. NO live calls.
// The CRYPTO is real (computeProposalHash + signReceipt/verifyReceipt, real ed25519 keypair); only I/O is injected —
// exactly the boundary the deployed gateway has.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGateway } from '../src/handlers.mjs';
import { createInMemoryStore } from '../src/store.mjs';
import { computeProposalHash, verifyReceipt } from '../src/actions.mjs';
import { generateSigningKeypair } from '../src/bundle.mjs';

const KNOWN = '6cf7e861-546a-4b9f-b937-39182a5bd395'; // the live Pocket room — the session the demo call is ABOUT
const FULL = ['sessions:read', 'sessions:write', 'pocket:voice', 'pocket:dial'];
const { publicKey: PUB, privateKey: KEY } = generateSigningKeypair();

// A CARTER-bound token: `sl ring-owner` runs under the owner's human identity, so ctx.humanId = the person whose phone
// rings. An asking agent (atlas) supplies requestedBy as a display label — it can NEVER redirect the ring (below).
const verifyToken = async (headers) => {
  const a = headers && (headers.authorization || headers.Authorization);
  if (a === 'Bearer carter') return { humanId: 'consumer-carter', principal: 'consumer-carter', scopes: FULL };
  if (a === 'Bearer noscope') return { humanId: 'consumer-carter', principal: 'consumer-carter', scopes: ['sessions:read'] };
  return null;
};

// Build ONE gateway wired as the deploy would be, and expose the injected-I/O trip-wires the tests assert on.
function makeDemoGateway() {
  const rings = [];                 // every ring the pushBackend received (the APNs input the phone gets)
  const postCalls = [];             // every governed human write the api client received
  let lastPost = null;
  // The api /human-message client (INJECTED I/O): echoes the deterministic clientId (= confirmation hash) as the
  // landed event identity, authored as human-mrrcarter — the exact success shape the real client parses.
  const postHumanMessage = async (sessionId, message, { clientId, token } = {}) => {
    lastPost = { sessionId, message, clientId, token };
    postCalls.push(lastPost);
    return JSON.stringify({
      ok: true,
      message: { id: clientId, cursor: 'c-1', senderId: 'human-mrrcarter', message, sessionId },
      event: { eventId: clientId, sequenceId: 5001, agent: { id: 'human-mrrcarter' } },
    });
  };
  // sl runner (INJECTED I/O): the read-back VERIFY re-reads the landed human write (eventId === the clientId it just
  // posted, authored by human-mrrcarter) so verifyHumanMessageLanded confirms the real landing.
  const run = (args) => {
    if (args[1] === 'read') {
      const mid = lastPost ? lastPost.clientId : '';
      return JSON.stringify({ events: [{ eventId: mid, event: 'session_message', agent: { id: 'human-mrrcarter' }, sequenceId: 5001 }] });
    }
    return '{}';
  };
  const gw = createGateway({
    verifyToken,
    knownSessionIdsFor: async () => [KNOWN],          // consumer-carter is a member of the demo room
    pushBackend: async (input) => { rings.push(input); return { dialId: 'dial_' + rings.length, dispatched: true }; },
    postHumanMessage,
    run,
    store: createInMemoryStore(),
    signingKey: KEY, signingKeyId: 'gw-key',
    now: () => '2026-07-18T12:02:00Z',
    agent: 'claude-pocket-relay',
  });
  return { gw, rings, postCalls };
}

const ringOwner = (gw, body, token = 'Bearer carter') => gw.handle({ method: 'POST', path: '/dial/ring-owner', headers: { authorization: token }, body });
const execute = (gw, body, token = 'Bearer carter') => gw.handle({ method: 'POST', path: '/actions/execute', headers: { authorization: token }, body });
const parse = (r) => (typeof r.body === 'string' ? JSON.parse(r.body) : r.body);

// A governed reply-back proposal: a TOP-LEVEL humanMessage (targetSequence 0 sentinel) to the session the ring carried.
function replyProposal(targetSessionId, text, id = 'ring_reply_1') {
  const p = { id, kind: 'humanMessage', targetSessionId, targetSequence: 0, renderedPreview: text, requiresConfirmation: true, createdAt: '2026-07-18T12:00:00Z', sourceQuestionId: null };
  p.proposalHash = computeProposalHash(p);
  return p;
}
const confirm = (p) => ({ proposalId: p.id, confirmedProposalHash: p.proposalHash, confirmedAt: '2026-07-18T12:01:00Z' });

// ---- BEAT 4: "call user" — the ring says WHO is asking + the DECISION + carries the session -------------------------

test('BEAT 4: ring-owner (decisionYours) rings the owner with "this is [caller]" + the decision + the session', async () => {
  const { gw, rings } = makeDemoGateway();
  const question = 'Ship the auth-boundary PR #752? Two-key both landed.';
  const res = await ringOwner(gw, { question, kind: 'decisionYours', requestedBy: 'claude-atlas', context: { sessionId: KNOWN, checkpointId: 'cp_752' } });
  assert.equal(res.status, 200);
  assert.equal(parse(res).dispatched, true);
  assert.equal(parse(res).kind, 'decisionYours');
  assert.equal(rings.length, 1, 'exactly one ring dispatched');
  const ring = rings[0];
  // WHO is calling (the demo's "this is …claude atlas") — the spoken/CallKit caller identity, byte-parity with Swift.
  assert.equal(ring.callerName, 'Senti · claude-atlas needs your decision');
  // WHAT they need (the decision) rides the ring verbatim.
  assert.equal(ring.message, question);
  // WHICH session the call is about — threaded so the answer can post back to it (beat 3).
  assert.equal(ring.sessionId, KNOWN);
  assert.equal(ring.checkpointId, 'cp_752');
  assert.equal(ring.priority, 'high', 'a decision-needed ring is high priority');
  // The stored signal (GET /dial?id= LEAN-ring hydration) carries the same session — the app decodes the full context.
  assert.equal(ring.storedSignal.context.sessionId, KNOWN);
});

test('BEAT 4: pickOption ring carries the OPTIONS to read aloud (Atlas #110 speaks them)', async () => {
  const { gw, rings } = makeDemoGateway();
  const res = await ringOwner(gw, { question: 'Which rollout?', kind: 'pickOption', options: ['ship now', 'hold for review'], requestedBy: 'claude-atlas', context: { sessionId: KNOWN } });
  assert.equal(res.status, 200);
  const ring = rings[0];
  assert.equal(ring.callerName, 'Senti · claude-atlas needs you to choose');
  assert.deepEqual(ring.options, ['ship now', 'hold for review'], 'the options ride the ring so the phone reads them aloud');
});

test('BEAT 4 SECURITY: the ring TARGET is the verified caller, never the body (confused-deputy-safe)', async () => {
  const { gw, rings } = makeDemoGateway();
  // A caller tries to redirect the ring to someone else via the body — it MUST be ignored; the ring targets ctx.humanId.
  const res = await ringOwner(gw, { question: 'ring the victim', kind: 'go', requestedBy: 'attacker', humanId: 'consumer-victim', targetHumanId: 'consumer-victim', context: { sessionId: KNOWN } });
  assert.equal(res.status, 200);
  assert.equal(rings[0].humanId, 'consumer-carter', 'ring targets the VERIFIED human, not the body-supplied victim');
});

test('BEAT 4: ring-owner requires the pocket:dial capability (least-privilege)', async () => {
  const { gw } = makeDemoGateway();
  const res = await ringOwner(gw, { question: 'x', kind: 'go', context: { sessionId: KNOWN } }, 'Bearer noscope');
  assert.equal(res.status, 403);
  assert.match(parse(res).error, /pocket:dial/);
});

// ---- BEAT 3 + THE ROUND-TRIP: the answer writes back to the SAME session via the REAL governed write ----------------

test('ROUND-TRIP: ring carries sessionId -> the answer governed-writes back to that SAME session (real ed25519 receipt)', async () => {
  const { gw, rings, postCalls } = makeDemoGateway();

  // 1) the ring goes out about the demo room (beat 4).
  await ringOwner(gw, { question: 'Ship #752?', kind: 'decisionYours', requestedBy: 'claude-atlas', context: { sessionId: KNOWN, checkpointId: 'cp_752' } });
  const ringSession = rings[0].sessionId; // the session the call is ABOUT — the answer must land HERE.

  // 2) the owner answers "ship it" on the call -> the app proposes a governed humanMessage back to ringSession.
  const p = replyProposal(ringSession, 'Carter: ship it — two-key landed, PR #752.');
  const res = await execute(gw, { proposal: p, confirmation: confirm(p) });
  assert.equal(res.status, 200);
  const receipt = parse(res);

  // the write is REAL + governed:
  assert.equal(receipt.status, 'posted');
  assert.equal(receipt.targetSessionId, ringSession, 'ROUND-TRIP: the write lands in the SAME session the ring carried');
  assert.equal(receipt.confirmedProposalHash, p.proposalHash, 'the receipt is bound to the confirmed proposal hash');
  assert.equal(verifyReceipt(receipt, PUB), true, 'the receipt verifies against the gateway ed25519 key — REAL crypto, not a stub');
  // authored AS the human (the "I reply -> it posts as me" narrative), to the ring's session, with the answer text.
  assert.equal(postCalls.length, 1, 'exactly one governed write');
  assert.equal(postCalls[0].sessionId, ringSession);
  assert.equal(postCalls[0].message, 'Carter: ship it — two-key landed, PR #752.');
  assert.equal(postCalls[0].clientId, p.proposalHash, 'the api client id = the proposal hash (server-side idempotency binds to THIS proposal)');
});

test('ROUND-TRIP idempotency: replaying the answer never double-writes (one governed post, same receipt)', async () => {
  const { gw, rings, postCalls } = makeDemoGateway();
  await ringOwner(gw, { question: 'Ship #752?', kind: 'decisionYours', requestedBy: 'claude-atlas', context: { sessionId: KNOWN } });
  const p = replyProposal(rings[0].sessionId, 'Carter: ship it.');
  const body = { proposal: p, confirmation: confirm(p) };
  const r1 = parse(await execute(gw, body));
  const r2 = parse(await execute(gw, body)); // a naive retry of the SAME answer
  assert.equal(r1.status, 'posted');
  assert.equal(r2.status, 'posted');
  assert.equal(r2.confirmedProposalHash, r1.confirmedProposalHash, 'the retry returns the same terminal receipt');
  assert.equal(postCalls.length, 1, 'the governed write executed exactly ONCE — no duplicate post as the human');
});

test('ROUND-TRIP authz: the answer can only write to a session the caller belongs to (no confused-deputy on the write)', async () => {
  const { gw, postCalls } = makeDemoGateway();
  const p = replyProposal('00000000-0000-0000-0000-000000000000', 'stray write'); // NOT a member session
  const res = await execute(gw, { proposal: p, confirmation: confirm(p) });
  assert.equal(res.status, 403);
  assert.match(parse(res).error, /not a member/);
  assert.equal(postCalls.length, 0, 'no governed write for a non-member target session');
});

#!/usr/bin/env node
// warden-live-verify.mjs — Warden's INDEPENDENT end-to-end proof of the first real Pocket governed write.
//
// It stands in for the phone: builds a typed humanMessage ActionProposal, confirms it, POSTs to the LIVE-demo
// gateway (bc44467 live-demo-server.mjs) with a REAL SENTI user-session bearer, and then INDEPENDENTLY proves the
// message actually landed in the room — authored as human-<you> — at the sequence the receipt claims. Nothing is
// mocked: real /auth/me, real /human-message, real read-back via `sl`.
//
// Run ON THE MAC that hosts the gateway (its `sl` is an authed MEMBER; the SENTI token is the Mac's mrrCarter session):
//   GATEWAY_URL=http://localhost:8787 \
//   SENTI_TOKEN="$(<however sl emits the current session bearer>)" \
//   ROOM=6cf7e861-546a-4b9f-b937-39182a5bd395 \
//   SL_BIN=sl \
//   node services/pocket-gateway/scripts/warden-live-verify.mjs
// The token is used transiently as the Authorization bearer only — never logged, printed, or written anywhere.
//
// PASS criteria (all must hold): 200 + status 'posted'; a real sequenceId; the receipt's authored sender is human-*;
// and an INDEPENDENT `sl session read` (anchored on that sequence) finds the exact proposalHash message authored by
// that same human-* sender. Any miss => FAIL (fail-closed), and we print WHY.
import { computeProposalHash } from '../src/actions.mjs'; // the GATED hash — single source of truth (no divergence)
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';

const GATEWAY = (process.env.GATEWAY_URL || 'http://localhost:8787').replace(/\/+$/, '');
const TOKEN = process.env.SENTI_TOKEN || '';
const ROOM = process.env.ROOM || '6cf7e861-546a-4b9f-b937-39182a5bd395';
const SL_BIN = process.env.SL_BIN || 'sl';
const MSG = process.env.MSG || `warden live-write verify ${new Date().toISOString()} · ${crypto.randomBytes(3).toString('hex')}`;

const fail = (why, extra) => { console.error(`\n❌ VERIFY FAILED: ${why}`); if (extra !== undefined) console.error(extra); process.exit(1); };
const ok = (m) => console.log(`✓ ${m}`);

if (!TOKEN) fail('SENTI_TOKEN not set — supply a real SENTI user-session bearer (transient; never committed/logged).');

// 1) Build the typed humanMessage proposal + its gated hash, and a single-use confirmation bound to that exact hash.
const proposal = {
  id: 'warden-verify-' + crypto.randomBytes(8).toString('hex'),
  kind: 'humanMessage',
  targetSessionId: ROOM,
  targetSequence: 0,                 // top-level human write sentinel
  renderedPreview: MSG,
  createdAt: Date.now(),
  sourceQuestionId: null,
  requiresConfirmation: true,
};
proposal.proposalHash = computeProposalHash(proposal);
const confirmation = { proposalId: proposal.id, confirmedProposalHash: proposal.proposalHash, confirmedAt: new Date().toISOString() };
ok(`built proposal id=${proposal.id} hash=${proposal.proposalHash}`);

// 2) POST /actions/execute with the caller's REAL bearer.
let res, body;
try {
  res = await fetch(`${GATEWAY}/actions/execute`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ proposal, confirmation }),
  });
  body = await res.json();
} catch (e) { fail('POST /actions/execute threw (gateway reachable? tunnel up?)', e && e.message); }
ok(`POST /actions/execute -> HTTP ${res.status}`);
if (res.status !== 200) fail(`gateway did not return 200 (got ${res.status})`, body);

// The receipt may be the body itself or under body[proposal.id] (map-shaped). Normalize.
const rec = (body && (body.status || body.receipt)) ? body : (body && body[proposal.id]) ? body[proposal.id] : body;
if (!rec || rec.status !== 'posted') fail(`not a 'posted' receipt (status=${rec && rec.status})`, body);
ok(`receipt status = posted`);

// 3) Extract the real sequence from the receipt. The posted humanMessage receipt carries it in its ActionResultRef:
//    receipt.result = {kind:'sequence', sequenceId} (actions.mjs L137/L164). rec.sequenceId / __emitted do NOT exist in
//    the serialized HTTP body (Relay review — verified at source: receiptResponse -> json(200, receipt)).
const receipt = rec.receipt || rec;
const seq = receipt.result?.sequenceId ?? rec.result?.sequenceId;
const senderReported = receipt.result?.senderId; // not surfaced today (result is {kind,sequenceId}); read-back is the authority
if (!(typeof seq === 'number' && seq > 0)) fail('no real sequenceId in receipt.result (message did not durably land)', rec);
ok(`receipt result.sequenceId = ${seq}`);

// 4) INDEPENDENT proof: read the room ourselves (member `sl`), anchored on the claimed sequence, and confirm the
//    exact proposalHash message is there authored by a human-* identity. This is the real cross-service assertion.
const readArgs = ['session', 'read', ROOM, '--remote', '--before-sequence', String(seq + 1), '--tail', '25', '--no-view', '--json'];
let events = [];
try {
  const out = execFileSync(SL_BIN, readArgs, { encoding: 'utf8', timeout: 20_000, maxBuffer: 8 * 1024 * 1024 });
  const j = JSON.parse(out); events = j.events || j || [];
} catch (e) { fail('independent `sl session read` failed (is SL_BIN a member of the room?)', e && (e.stdout || e.message)); }

// The room event's eventId is a SERVER id (cli-<uuid>), NOT the proposalHash, and the clientId isn't a queryable event
// field (Relay review — verified vs a live event: eventId=cli-3b96f15d-...). Match on the SEQUENCE the receipt reports:
// the message IS the event at that exact seq, and we read --before-sequence seq+1 so it's in the window. Then corroborate
// the UNIQUE per-run content (payload.message) so we're certain it's OUR write, not merely something at that sequence.
const hit = events.find((e) => e.sequenceId === seq);
if (!hit) fail(`independent read-back did NOT find an event at seq ${seq} — a real landing would be here`, events.map((e) => ({ eventId: e.eventId, seq: e.sequenceId, who: (e.agent && e.agent.id) || e.agentId })));
const content = hit.payload && (hit.payload.message ?? hit.payload.text);
if (content !== MSG) fail(`event at seq ${seq} does NOT carry our exact message content (unique per run)`, `got: ${JSON.stringify(String(content).slice(0, 100))}`);
const who = (hit.agent && hit.agent.id) || hit.agentId;
ok(`independent read-back FOUND our message: eventId=${hit.eventId} seq=${hit.sequenceId} (content matches, unique per run)`);
if (!(typeof who === 'string' && who.startsWith('human-'))) fail(`the landed message is NOT authored by a human-* identity (author=${who}) — it must post AS the human, not an agent`);
ok(`authored by ${who}`);
const expectedHuman = process.env.EXPECTED_HUMAN;
if (expectedHuman && who !== expectedHuman) fail(`author ${who} != EXPECTED_HUMAN ${expectedHuman}`);
if (senderReported && who !== senderReported) fail(`read-back author (${who}) != receipt-reported sender (${senderReported}) — cross-service identity mismatch`);

console.log(`\n✅ FIRST REAL POCKET WRITE VERIFIED — our exact message (unique per-run content) landed in room ${ROOM} at sequence ${hit.sequenceId}, authored as ${who}, and the gateway receipt reported that same sequence. Real post · real authoring (human, not agent) · real independent read-back. (Local gateway + dev receipt key, honestly labeled; message + authoring + landing are REAL.)`);

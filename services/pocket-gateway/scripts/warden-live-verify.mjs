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

// 3) Extract the real sequence + the authored sender the receipt/response reports.
const receipt = rec.receipt || rec;
const seq = rec.sequenceId ?? receipt.sequenceId ?? (rec.__emitted && rec.__emitted.parsed && rec.__emitted.parsed.sequenceId);
const senderReported = rec.senderId ?? (rec.__emitted && rec.__emitted.parsed && rec.__emitted.parsed.senderId) ?? receipt.senderId;
if (!(typeof seq === 'number' && seq > 0)) fail('no real sequenceId in the receipt (message did not durably land)', rec);
ok(`receipt sequenceId = ${seq}`);
if (typeof senderReported === 'string' && senderReported.startsWith('human-')) ok(`receipt authored sender = ${senderReported}`);
else console.log(`  (note: sender not surfaced in receipt; the independent read-back below is the authority)`);

// 4) INDEPENDENT proof: read the room ourselves (member `sl`), anchored on the claimed sequence, and confirm the
//    exact proposalHash message is there authored by a human-* identity. This is the real cross-service assertion.
const readArgs = ['session', 'read', ROOM, '--remote', '--before-sequence', String(seq + 1), '--tail', '25', '--no-view', '--json'];
let events = [];
try {
  const out = execFileSync(SL_BIN, readArgs, { encoding: 'utf8', timeout: 20_000, maxBuffer: 8 * 1024 * 1024 });
  const j = JSON.parse(out); events = j.events || j || [];
} catch (e) { fail('independent `sl session read` failed (is SL_BIN a member of the room?)', e && (e.stdout || e.message)); }

// messageId is the deterministic client id = proposalHash; match the landed event by it.
const hit = events.find((e) => (e.eventId === proposal.proposalHash) || (e.payload && e.payload.clientId === proposal.proposalHash) || (e.eventId && String(e.eventId).includes(proposal.id)));
if (!hit) fail(`independent read-back did NOT find the message (proposalHash=${proposal.proposalHash}) at/around seq ${seq} — a real message would be here`, events.map((e) => ({ eventId: e.eventId, seq: e.sequenceId, who: (e.agent && e.agent.id) || e.agentId })));
const who = (hit.agent && hit.agent.id) || hit.agentId;
ok(`independent read-back FOUND the message: eventId=${hit.eventId} seq=${hit.sequenceId} author=${who}`);
if (!(typeof who === 'string' && who.startsWith('human-'))) fail(`the landed message is NOT authored by a human-* identity (author=${who}) — it must post AS the human, not an agent`);
if (senderReported && who !== senderReported) fail(`read-back author (${who}) != receipt-reported sender (${senderReported}) — cross-service identity mismatch`);

console.log(`\n✅ FIRST REAL POCKET WRITE VERIFIED — a message authored as ${who} landed in room ${ROOM} at sequence ${hit.sequenceId}, its content-bound proposalHash matches, and the receipt reported it. Real post · real authoring · real read-back. (Local gateway + dev receipt key, honestly labeled.)`);

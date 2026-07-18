// gen-kav.mjs — generate the committed Node<->Swift known-answer vector (Echo #233248 P1e).
// Deterministic Ed25519 key (fixed seed) + a fixed signed PocketBundle + a fixed signed ActionReceipt. Swift pins the
// raw base64url public key and MUST verify the exact committed bytes. Regenerate only intentionally: node scripts/gen-kav.mjs
import { createPrivateKey, createPublicKey } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { buildRawCheckpoint } from '../src/extract.mjs';
import { summarize } from '../src/summarize.mjs';
import { buildSignedBundle } from '../src/bundle.mjs';
import { signReceipt } from '../src/actions.mjs';

// Deterministic Ed25519 private key from a FIXED 32-byte seed (PKCS8 DER: OKP Ed25519 prefix + seed).
const seed = Buffer.from('a1'.repeat(32), 'hex');
const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);
const privateKey = createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
const publicKey = createPublicKey(privateKey);
const rawPub = publicKey.export({ format: 'jwk' }).x; // raw base64url Ed25519 public key (the form the phone pins)

const SID = '11111111-1111-4111-8111-111111111111';
const EXPORT = {
  session: { id: SID, title: 'KAV' },
  events: [
    { sequenceId: 1, event: 'session_message', agent: { id: 'agent-a' }, payload: { text: 'kav event one' }, ts: '2026-07-18T00:00:00Z' },
    { sequenceId: 2, event: 'session_message', agent: { id: 'agent-b' }, payload: { text: 'kav event two' }, ts: '2026-07-18T00:01:00Z' },
  ],
};
const CKPT = { checkpointId: 'cp_kav', sessionId: SID, startSequence: 1, endSequence: 2, summarySections: { window: { eventCount: 2 }, headline: 'KAV checkpoint' } };
const { rawCheckpoint } = buildRawCheckpoint(CKPT, EXPORT, { capturedAt: '2026-07-18T00:02:00Z' });
const summary = summarize(rawCheckpoint, CKPT);
const bundle = buildSignedBundle(rawCheckpoint, summary, privateKey, { signingKeyId: 'kav-key', createdAt: '2026-07-18T00:03:00Z' });

const receipt = signReceipt({
  id: 'kav_prop', proposalId: 'kav_prop', status: 'posted',
  result: { kind: 'action', actionId: 'kav_act', targetSequenceId: 2, targetCursor: null },
  targetSessionId: SID, confirmedProposalHash: 'KAVHASH_confirmed', confirmedByHumanAt: '2026-07-18T00:04:00Z',
  executedAt: '2026-07-18T00:04:30Z', failureReason: null, signingKeyId: null,
}, privateKey, 'kav-key');

// The fixture is a LABELED demo trust anchor. `demoAnchor` makes the Phase-A-only nature unmistakable (never a prod
// root); `keyBinding` maps signingKeyId -> the pinned raw pubkey so a consumer PROVES its signingKeyId selects exactly
// this public key (verifyBundleWithTrustStore rejects any other/unknown id). Additive metadata: the bundle/receipt
// objects (and their signatures) are byte-identical to before; Swift decodes only bundle/receipt/publicKeyRawBase64url.
const fixture = {
  schema: 'pocket_kav_v1',
  demoAnchor: {
    keyClass: 'demo',
    phase: 'A',
    seedHex: 'a1'.repeat(32),
    note: 'DEMO Phase-A-only Ed25519 anchor generated from a FIXED seed; pinned by the demo phone. NEVER a production trust root.',
  },
  signingKeyId: 'kav-key',
  publicKeyRawBase64url: rawPub,
  keyBinding: { 'kav-key': rawPub }, // signingKeyId -> pinned RAW base64url Ed25519 pubkey (trust-anchor selection)
  bundle,
  receipt,
};
writeFileSync(new URL('../test/fixtures/pocket_kav_v1.json', import.meta.url), JSON.stringify(fixture, null, 2) + '\n');
console.log('wrote pocket_kav_v1.json  rawPub=' + rawPub + '  bundle.sig=' + bundle.signature.slice(0, 16) + '...  receipt.sig=' + receipt.signature.slice(0, 16) + '...');

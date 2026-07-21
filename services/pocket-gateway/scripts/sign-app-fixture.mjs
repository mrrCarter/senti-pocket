// sign-app-fixture.mjs — sign the app's rich demo bundle (canonical_checkpoint.json) so the phone can VERIFY it,
// unblocking the Phase-A briefing. The gateway lane owns signing (Node ed25519); the fixture's ISO createdAt/ts decode
// to the same epoch-ms Swift's canonicalBytesUtf8 uses, so a Relay signature verifies under the Swift verify path.
//
// FRESH RANDOM key each run (private NOT committed — non-forgeable, same posture as warden's KAV). Prints the pubkey to
// add to pocketTrustedGatewayKeys + the canonical sha256 for a Swift byte-verify. Re-run to re-sign after a fixture edit.
//   node scripts/sign-app-fixture.mjs <unsigned.json> [outPath]
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import {
  canonicalBundlePayload, canonicalBundleBytes, signBundle, verifyBundle,
  validateBundleIngress, generateSigningKeypair,
} from '../src/bundle.mjs';

const inPath = process.argv[2] || 'C:/tmp/canonical_checkpoint.json';
const outPath = process.argv[3] || 'C:/tmp/canonical_checkpoint.signed.json';
const SIGNING_KEY_ID = 'pocket-demo-app-fixture';

const fx = JSON.parse(readFileSync(inPath, 'utf8'));
const { publicKey, privateKey } = generateSigningKeypair();
const rawPub = publicKey.export({ format: 'jwk' }).x; // raw base64url — the value the phone pins

// The fixture bundle IS the draft. Strip the placeholder signature; set the trusted signingKeyId (bound in canonical).
const draft = { ...fx, signature: '', signingKeyId: SIGNING_KEY_ID };

// It must be a semantically-valid, in-budget bundle BEFORE we sign it (same gate the phone applies on consume).
const ingress = validateBundleIngress(draft);
if (!ingress.ok) {
  console.error('INGRESS FAILED — fixture is not signable as-is:\n- ' + ingress.errors.join('\n- '));
  process.exit(2);
}

const signed = signBundle(draft, privateKey, SIGNING_KEY_ID);
signed.signature = Buffer.from(signed.signature, 'base64').toString('base64url'); // base64url, matching the KAV convention
const sha = createHash('sha256').update(canonicalBundleBytes(signed)).digest('hex');
const roundTrip = verifyBundle(signed, publicKey); // Node lenient base64 decode verifies the base64url signature

writeFileSync(outPath, JSON.stringify(signed, null, 2) + '\n');
console.log(JSON.stringify({
  signingKeyId: SIGNING_KEY_ID,
  publicKeyRawBase64url: rawPub,            // add to pocketTrustedGatewayKeys
  canonicalSha256Hex: sha,                  // Swift: canonicalBytesUtf8 over the decoded fixture must sha256 to THIS
  canonicalBytesUtf8: canonicalBundlePayload(signed),
  roundTripVerified: roundTrip,
  wroteSignedFixture: outPath,
}, null, 2));
process.exit(roundTrip ? 0 : 1);

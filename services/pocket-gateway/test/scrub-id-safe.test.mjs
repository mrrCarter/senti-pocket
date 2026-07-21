// scrub-id-safe.test.mjs — scrubIdSafe applies only explicit-format secret rules over IDENTIFIER fields, so a
// well-formed hash/uuid id passes verbatim (no redaction-collapse / grounding break) while a secret-PREFIXED id still
// redacts. scrubText (full rules incl. entropy catch-alls) is unchanged.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { scrubText, scrubIdSafe } from '../src/scrub.mjs';

test('scrubIdSafe: a hash/opaque id passes VERBATIM (scrubText would redact it via the entropy catch-alls)', () => {
  const hashId = 'a'.repeat(64);                 // 64-hex -> scrubText hex-secret
  const opaqueId = 'cp_' + 'A1b2C3d4'.repeat(8); // 67-char base64url-ish -> scrubText opaque-token
  // scrubText (full) redacts them — that was the bug when applied to ids:
  assert.ok(scrubText(hashId).text.includes('[REDACTED'), 'scrubText redacts a bare hash');
  assert.ok(scrubText(opaqueId).text.includes('[REDACTED'), 'scrubText redacts a long opaque id');
  // scrubIdSafe leaves them verbatim:
  assert.equal(scrubIdSafe(hashId).text, hashId);
  assert.equal(scrubIdSafe(opaqueId).text, opaqueId);
  assert.deepEqual(scrubIdSafe(hashId).redactions, []);
  // distinct hash ids stay DISTINCT (the collapse the full scrub caused):
  assert.notEqual(scrubIdSafe(hashId).text, scrubIdSafe('b'.repeat(64)).text);
});

test('scrubIdSafe: a secret-PREFIXED value in an id field is STILL redacted (defense-in-depth)', () => {
  assert.ok(scrubIdSafe('sk-' + 'a'.repeat(20)).text.includes('[REDACTED:api-key]'));
  assert.ok(scrubIdSafe('atk_' + 'a'.repeat(20)).text.includes('[REDACTED:aidenid-token]'));
  const jwt = 'eyJ' + 'A'.repeat(10) + '.' + 'B'.repeat(10) + '.' + 'C'.repeat(10);
  assert.ok(scrubIdSafe(jwt).text.includes('[REDACTED:jwt]'));
  assert.ok(scrubIdSafe('ghp_' + 'a'.repeat(20)).text.includes('[REDACTED:github-token]'));
});

test('scrubText is unchanged (full rules), non-secret text untouched', () => {
  assert.ok(scrubText('a'.repeat(64)).text.includes('[REDACTED'));
  assert.equal(scrubText('a normal sentence').text, 'a normal sentence');
  assert.equal(scrubIdSafe('sess-1').text, 'sess-1'); // a short plain id: untouched by both
});

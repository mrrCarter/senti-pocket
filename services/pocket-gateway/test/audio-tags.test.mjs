// audio-tags.test.mjs — author-once-with-tags, strip-for-plain-backends.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stripAudioTags, hasAudioTags, splitTagged, AUDIO_TAG_HINT } from '../src/audio-tags.mjs';

test('stripAudioTags removes bracketed cues + collapses whitespace', () => {
  assert.equal(stripAudioTags('[warm] Two agents shipped. [pause] One blocker: the Mac.'),
    'Two agents shipped. One blocker: the Mac.');
  assert.equal(stripAudioTags('No tags here.'), 'No tags here.');
  assert.equal(stripAudioTags('[reassuring] It verified.'), 'It verified.');
  assert.equal(stripAudioTags(''), '');
  assert.equal(stripAudioTags(null), '');
  assert.equal(stripAudioTags(42), '');
});

test('lowercase-led only: real bracketed text ([ERROR], [TODO], [0]) is NOT stripped', () => {
  assert.equal(stripAudioTags('value [0] and [ERROR] and [TODO] stay'), 'value [0] and [ERROR] and [TODO] stay');
  assert.equal(hasAudioTags('only [ERROR] here'), false);
});

test('hasAudioTags detects a lowercase cue', () => {
  assert.equal(hasAudioTags('[calm] hi'), true);
  assert.equal(hasAudioTags('plain text'), false);
  assert.equal(hasAudioTags(''), false);
});

test('splitTagged returns { tagged, plain } — author once, serve both', () => {
  const { tagged, plain } = splitTagged('  [serious] The gate held. [emphasis] Verified.  ');
  assert.equal(tagged, '[serious] The gate held. [emphasis] Verified.');
  assert.equal(plain, 'The gate held. Verified.');
});

test('AUDIO_TAG_HINT is a usable prompt fragment (sparse, prosody-only)', () => {
  assert.ok(typeof AUDIO_TAG_HINT === 'string' && AUDIO_TAG_HINT.length > 20);
  assert.match(AUDIO_TAG_HINT, /square brackets/i);
});

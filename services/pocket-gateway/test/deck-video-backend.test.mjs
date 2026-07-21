// deck-video-backend.test.mjs — CI-safe contract tests (no resvg/ffmpeg binaries needed; the real end-to-end render
// is proven separately on a host with the binaries). Confirms the injectable shape + the fail-closed guards.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createDeckVideoBackend } from '../src/deck/deck-video-backend.mjs';

test('createDeckVideoBackend requires resvgBin + ffmpegBin (no half-configured backend)', () => {
  assert.throws(() => createDeckVideoBackend({}), /required/);
  assert.throws(() => createDeckVideoBackend({ resvgBin: 'x' }), /required/);
  assert.throws(() => createDeckVideoBackend({ ffmpegBin: 'x' }), /required/);
});

test('exposes exactly the {rasterize, encodeVideo} shape assembleDeckVideo injects', () => {
  const b = createDeckVideoBackend({ resvgBin: 'r', ffmpegBin: 'f' });
  assert.equal(typeof b.rasterize, 'function');
  assert.equal(typeof b.encodeVideo, 'function');
});

test('encodeVideo rejects an empty frame set (never emits a fake/empty video)', () => {
  const b = createDeckVideoBackend({ resvgBin: '/nonexistent/resvg', ffmpegBin: '/nonexistent/ffmpeg' });
  assert.throws(() => b.encodeVideo({ frames: [] }), /no frames/);
  assert.throws(() => b.encodeVideo({}), /no frames/);
});

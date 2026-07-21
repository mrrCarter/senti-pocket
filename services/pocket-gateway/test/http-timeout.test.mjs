// http-timeout.test.mjs — timeoutSignal returns an any-runtime abortable AbortSignal (Warden hardening note 2).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { timeoutSignal } from '../src/http-timeout.mjs';

test('timeoutSignal returns an AbortSignal, not aborted at t=0', () => {
  const s = timeoutSignal(1000);
  assert.ok(s, 'a signal is returned on this runtime');
  assert.equal(typeof s.aborted, 'boolean');
  assert.equal(s.aborted, false, 'not aborted initially');
});

test('timeoutSignal aborts after the timeout elapses (native path)', async () => {
  const s = timeoutSignal(20);
  assert.equal(s.aborted, false);
  await new Promise((r) => setTimeout(r, 60)); // > 20ms
  assert.equal(s.aborted, true, 'signal is aborted after the timeout');
});

test('timeoutSignal FALLBACK (no AbortSignal.timeout) still yields an aborting signal', async () => {
  const orig = AbortSignal.timeout;
  let stubbed = false;
  try {
    try { AbortSignal.timeout = undefined; stubbed = AbortSignal.timeout === undefined; } catch { stubbed = false; }
    if (!stubbed) return; // runtime won't let us hide the native factory — the native path above already covers behavior
    const s = timeoutSignal(20);
    assert.ok(s && typeof s.aborted === 'boolean', 'fallback returns an AbortController signal');
    assert.equal(s.aborted, false);
    await new Promise((r) => setTimeout(r, 60));
    assert.equal(s.aborted, true, 'fallback signal aborts after the timeout');
  } finally {
    AbortSignal.timeout = orig; // restore for any later tests
  }
});

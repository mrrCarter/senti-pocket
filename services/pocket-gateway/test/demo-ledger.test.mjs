// demo-ledger.test.mjs — adversarial regression gates for the crash/concurrency-safe reservation ledger (Pulse 17:53 +
// Echo 17:57 red-team, as required regression gates on the fresh SHA).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, symlinkSync, chmodSync, readdirSync, openSync, closeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createReservationLedger } from '../src/demo-ledger.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CAP = 'a'.repeat(64); // full sha256-shaped capId
const dir = () => { const d = mkdtempSync(join(tmpdir(), 'pdl-')); chmodSync(d, 0o700); return d; };
const mk = (d, over = {}) => createReservationLedger({ dir: d, capId: CAP, maxCalls: 5, maxBytes: 1000, ...over });
const statePath = (d, capId = CAP) => join(d, `pocket-demo-state-${capId.slice(0, 32)}.json`);

test('provision creates zero-spend; reserve to maxCalls then 429; byte budget', () => {
  const d = dir(); const L = mk(d, { maxCalls: 2, maxBytes: 100 });
  L.provision();
  assert.equal(L.stats().calls, 0);
  assert.equal(L.reserve(10).ok, true); assert.equal(L.reserve(10).ok, true);
  assert.equal(L.reserve(10).status, 429, 'call budget');
  const d2 = dir(); const L2 = mk(d2, { maxCalls: 100, maxBytes: 50 }); L2.provision();
  assert.equal(L2.reserve(40).ok, true); assert.equal(L2.reserve(20).status, 429, 'byte budget');
});

test('restart-safe: fresh instance sees persisted spend (pre-provisioned, not reset)', () => {
  const d = dir(); mk(d).provision(); const a = mk(d); a.reserve(7); a.reserve(7);
  const b = mk(d); assert.equal(b.stats().calls, 2); assert.equal(b.reserve(1).remainingCalls, 2);
});

// --- fail-closed on tamper/corruption (never reset+admit) ---
test('missing state after provision -> 503 (never recreated at runtime)', () => {
  const d = dir(); const L = mk(d); L.provision(); rmSync(statePath(d));
  assert.equal(L.reserve(1).status, 503);
});
test('corrupt JSON -> 503', () => { const d = dir(); mk(d).provision(); writeFileSync(statePath(d), 'not-json'); assert.equal(mk(d).reserve(1).status, 503); });
test('negative counters -> 503', () => { const d = dir(); mk(d).provision(); writeFileSync(statePath(d), JSON.stringify({ v: 1, capId: CAP, maxCalls: 5, maxBytes: 1000, calls: -3, bytes: 0 })); assert.equal(mk(d).reserve(1).status, 503); });
test('wrong version/schema -> 503', () => { const d = dir(); mk(d).provision(); writeFileSync(statePath(d), JSON.stringify({ v: 2, capId: CAP, maxCalls: 5, maxBytes: 1000, calls: 0, bytes: 0 })); assert.equal(mk(d).reserve(1).status, 503); });
test('capId mismatch -> 503', () => { const d = dir(); mk(d).provision(); writeFileSync(statePath(d), JSON.stringify({ v: 1, capId: 'b'.repeat(64), maxCalls: 5, maxBytes: 1000, calls: 0, bytes: 0 })); assert.equal(mk(d).reserve(1).status, 503); });
test('limits mismatch -> 503', () => { const d = dir(); mk(d).provision(); writeFileSync(statePath(d), JSON.stringify({ v: 1, capId: CAP, maxCalls: 999, maxBytes: 1000, calls: 0, bytes: 0 })); assert.equal(mk(d).reserve(1).status, 503); });

// --- storage errors never crash the process; unsafe dirs refused ---
test('unwritable / missing dir -> 503, process survives (no throw out of reserve)', () => {
  const L = createReservationLedger({ dir: '/nonexistent-xyz-12345', capId: CAP, maxCalls: 5, maxBytes: 100 });
  assert.equal(L.reserve(1).status, 503); // does not throw
});
test('provision refuses a symlinked persist dir (no-link invariant)', () => {
  const real = dir(); const link = join(tmpdir(), 'pdl-link-' + Math.floor(Math.random() * 1e9));
  try { symlinkSync(real, link); } catch { return; } // skip if symlink not permitted
  assert.throws(() => createReservationLedger({ dir: link, capId: CAP, maxCalls: 5, maxBytes: 100 }).provision());
});
test('provision refuses a world/group-accessible dir (restrictive-mode invariant)', () => {
  const d = dir(); chmodSync(d, 0o755);
  assert.throws(() => mk(d).provision());
});

// --- no stale-lock auto-steal ---
test('a held lock -> 503 (no steal); provision clears it (operator recovery)', () => {
  const d = dir(); const L = mk(d); L.provision();
  const fd = openSync(L._paths.lockPath, 'wx', 0o600); // simulate a crash-orphaned lock
  try {
    const r = createReservationLedger({ dir: d, capId: CAP, maxCalls: 5, maxBytes: 1000, lockRetries: 3, lockBackoffMs: 1 }).reserve(1);
    assert.equal(r.status, 503, 'held lock -> 503 (not stolen)');
  } finally { closeSync(fd); }
  L.provision(); // boot-time operator recovery clears the stale lock
  assert.equal(mk(d).reserve(1).ok, true, 'reserves again after operator recovery');
});

test('no leftover temp files after a reservation', () => {
  const d = dir(); const L = mk(d); L.provision(); L.reserve(3);
  assert.equal(readdirSync(d).filter((f) => f.endsWith('.tmp')).length, 0, 'no .tmp residue');
});

// --- the headline gate: N-process contention, no over-spend ---
test('~100-process contention -> successes == maxCalls (no overrun)', async () => {
  const d = dir(); const maxCalls = 50;
  createReservationLedger({ dir: d, capId: CAP, maxCalls, maxBytes: 1e6 }).provision();
  const env = { ...process.env, W_DIR: d, W_CAPID: CAP, W_CALLS: String(maxCalls), W_BYTES: '1000000', W_ATTEMPTS: '4' };
  const worker = () => new Promise((resolve) => { let out = ''; const p = spawn(process.execPath, [join(HERE, '_demo-ledger-worker.mjs')], { env }); p.stdout.on('data', (x) => (out += x)); p.on('close', () => resolve(Number(out.trim()) || 0)); });
  const oks = await Promise.all(Array.from({ length: 100 }, worker));
  const total = oks.reduce((a, b) => a + b, 0);
  assert.equal(total, maxCalls, `exactly ${maxCalls} across 100 processes (got ${total})`);
});

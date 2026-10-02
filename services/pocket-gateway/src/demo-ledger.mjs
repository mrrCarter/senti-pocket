// demo-ledger.mjs — crash/restart/concurrency-safe reservation ledger for the PUBLIC login-free demo capability.
//
// HONEST SCOPE: safe under a TRUSTED single host against process crashes, restarts, and CONCURRENT processes. It is
// NOT rollback-resistant against an adversary with filesystem write access to the ledger (that is the SAME trust
// boundary that holds the Cartesia provider key). The only true monotonic cost anchor against that is the Cartesia
// account-level hard cap (an operator action on Carter's provider account). Everything here is FAIL-CLOSED: any storage,
// lock, corruption, identity, or invariant error yields a DENY (429/503) and NEVER throws out of reserve()/NEVER
// synthesizes. Identity is the FULL sha256 of the capability (capId); fp16 elsewhere is display-only.
import { openSync, writeSync, fsyncSync, closeSync, readFileSync, renameSync, unlinkSync, lstatSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const MODE_FILE = 0o600;
function sleepMs(ms) { try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); } catch { /* */ } }

// lstat (never follows a symlink) + owner + restrictive-mode + real-directory invariants. Throws => caller refuses.
function assertSafeDir(dir, getuid) {
  const st = lstatSync(dir);
  if (!st.isDirectory()) throw new Error('persist path is not a real directory (symlink?)');
  if (getuid && st.uid !== getuid()) throw new Error('persist dir not owned by process uid');
  if ((st.mode & 0o077) !== 0) throw new Error('persist dir mode too permissive (require 0700)');
}
function fsyncDir(dir) { let fd; try { fd = openSync(dir, 'r'); fsyncSync(fd); } catch { /* some FS disallow dir fsync */ } finally { try { if (fd !== undefined) closeSync(fd); } catch { /* */ } } }
// Atomic durable write: unpredictable O_EXCL temp (never follows/overwrites a pre-created path), fsync temp, atomic
// rename over the target, fsync dir. A crypto-random name defeats the predictable-`${pid}.tmp` hardlink/symlink attack.
function writeStateAtomic(dir, statePath, obj) {
  const tmp = `${dir}/.pdu-${randomBytes(12).toString('hex')}.tmp`;
  const fd = openSync(tmp, 'wx', MODE_FILE); // O_CREAT|O_EXCL|O_WRONLY — fails on any pre-existing path
  try { writeSync(fd, Buffer.from(JSON.stringify(obj))); fsyncSync(fd); } finally { closeSync(fd); }
  try { renameSync(tmp, statePath); } catch (e) { try { unlinkSync(tmp); } catch { /* */ } throw e; }
  fsyncDir(dir);
}
// Strict read: missing (ENOENT) throws => DENY (state must be pre-provisioned; never recreate at runtime). Non-regular-
// file / permissive-mode / corrupt JSON / version|identity|limits|counter mismatch all throw => DENY.
function readStateStrict(statePath, capId, maxCalls, maxBytes) {
  const st = lstatSync(statePath);
  if (!st.isFile()) throw new Error('state is not a regular file');
  if ((st.mode & 0o077) !== 0) throw new Error('state mode too permissive');
  const j = JSON.parse(readFileSync(statePath, 'utf8'));
  if (!j || j.v !== 1 || j.capId !== capId) throw new Error('state version/identity mismatch');
  if (j.maxCalls !== maxCalls || j.maxBytes !== maxBytes) throw new Error('state limits mismatch');
  if (!Number.isSafeInteger(j.calls) || j.calls < 0 || !Number.isSafeInteger(j.bytes) || j.bytes < 0) throw new Error('state counters invalid');
  return { calls: j.calls, bytes: j.bytes };
}
// O_EXCL lock with a bounded retry but NO stale-steal (no age/PID heuristics). A crash-orphaned lock => stays contended
// => reserve() returns 503 until an OPERATOR restart (provision() clears it). Live contention resolves within the retry.
function acquireLock(lockPath, retries, backoffMs) {
  for (let i = 0; i < retries; i++) {
    try { return openSync(lockPath, 'wx', MODE_FILE); }
    catch (e) { if (e && e.code === 'EEXIST') { sleepMs(backoffMs); continue; } throw e; }
  }
  throw new Error('lock contended');
}
function releaseLock(fd, lockPath) { try { if (fd != null) closeSync(fd); } catch { /* */ } try { unlinkSync(lockPath); } catch { /* */ } }

/**
 * @param {{ dir:string, capId:string, maxCalls:number, maxBytes:number, now?:Function, getuid?:Function|null,
 *           lockRetries?:number, lockBackoffMs?:number }} o  capId = FULL sha256(bearer).
 */
export function createReservationLedger({ dir, capId, maxCalls, maxBytes, now = () => Date.now(), getuid = (process.getuid ? () => process.getuid() : null), lockRetries = 400, lockBackoffMs = 2 }) {
  const base = `${dir}/pocket-demo-state-${capId.slice(0, 32)}`;
  const statePath = `${base}.json`;
  const lockPath = `${base}.lock`;
  return {
    // BOOT (operator action, not request path): clear a stale lock (operator recovery), then pre-provision a zero-spend
    // ledger or validate the existing one. Throws => the caller REFUSES the capability (fail-closed at boot).
    provision() {
      assertSafeDir(dir, getuid);
      try { unlinkSync(lockPath); } catch (e) { if (e && e.code !== 'ENOENT') throw e; }
      let exists = true;
      try { lstatSync(statePath); } catch (e) { if (e && e.code === 'ENOENT') exists = false; else throw e; }
      if (!exists) writeStateAtomic(dir, statePath, { v: 1, capId, maxCalls, maxBytes, calls: 0, bytes: 0, provisionedAt: Math.floor(now() / 1000) });
      else readStateStrict(statePath, capId, maxCalls, maxBytes); // validate; throws => operator must resolve/rotate
      return { ok: true };
    },
    // REQUEST PATH: reserve 1 call + `bytes`. NEVER throws; every storage/lock/corruption error => 503 (no provider).
    reserve(bytes) {
      const b = (Number.isSafeInteger(bytes) && bytes >= 0) ? bytes : 0;
      let fd = null;
      try { fd = acquireLock(lockPath, lockRetries, lockBackoffMs); }
      catch (e) { return { ok: false, status: 503, error: (e && e.message === 'lock contended') ? 'demo_budget_locked' : 'demo_budget_io' }; }
      try {
        const cur = readStateStrict(statePath, capId, maxCalls, maxBytes); // missing/corrupt/mismatch => throws => 503
        if (cur.calls >= maxCalls || cur.bytes + b > maxBytes) return { ok: false, status: 429, error: 'demo_usage_exhausted' };
        writeStateAtomic(dir, statePath, { v: 1, capId, maxCalls, maxBytes, calls: cur.calls + 1, bytes: cur.bytes + b, updatedAt: Math.floor(now() / 1000) });
        return { ok: true, remainingCalls: maxCalls - (cur.calls + 1), remainingBytes: maxBytes - (cur.bytes + b) };
      } catch { return { ok: false, status: 503, error: 'demo_budget_io' }; }
      finally { releaseLock(fd, lockPath); }
    },
    stats() { try { const s = readStateStrict(statePath, capId, maxCalls, maxBytes); return { calls: s.calls, bytes: s.bytes, provisioned: true }; } catch { return { calls: NaN, bytes: NaN, provisioned: false }; } },
    _paths: { statePath, lockPath },
  };
}

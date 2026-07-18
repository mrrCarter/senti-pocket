// sl-runner.test.mjs — the sl invoker must be SHELL-FREE, boot-validate a TRUSTED absolute CLI entrypoint, pass a
// MINIMAL child env + bounded timeout, and byte-preserve injection metacharacters (Echo #233114 P0 + #233248 P1).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeSlRunner } from '../src/sl-runner.mjs';

// the entrypoint must resolve to the sentinelayer-cli package (basename check) — name it accordingly
const CLI = join(mkdtempSync(join(tmpdir(), 'slr-')), 'sentinelayer-cli.js');
writeFileSync(CLI, '// fake sentinelayer-cli.js for tests');
const NOT_CLI = join(mkdtempSync(join(tmpdir(), 'slr-')), 'random.js');
writeFileSync(NOT_CLI, '// not the cli');

test('dispatches via node + validated cli.js (no shell), byte-preserves metacharacters, minimal env, bounded timeout', () => {
  process.env.RELAY_TEST_SECRET = 'super-secret';
  let seen;
  const run = makeSlRunner({ cliJs: CLI, execFile: (cmd, args, o) => { seen = { cmd, args, o }; return '{}'; } });
  const evil = 'ok & calc.exe | echo %PATH% > x ^ "q" `n`';
  run(['session', 'reply', 'sid', '5', evil, '--agent', 'a']);
  assert.equal(seen.cmd, process.execPath, 'dispatches through node, never a shell');
  assert.equal(seen.args[0], CLI);
  assert.deepEqual(seen.args.slice(1), ['session', 'reply', 'sid', '5', evil, '--agent', 'a']);
  assert.equal(seen.args[5], evil, 'renderedPreview passed VERBATIM (not shell-interpreted)');
  assert.ok(seen.o.timeout > 0, 'child has a bounded timeout');
  assert.ok(seen.o.env && !('RELAY_TEST_SECRET' in seen.o.env), 'child env is MINIMAL — arbitrary parent secrets not inherited');
  delete process.env.RELAY_TEST_SECRET;
});

test('rejects untrusted/invalid CLI entrypoints at BOOT (flag, relative, missing, empty)', () => {
  assert.throws(() => makeSlRunner({ cliJs: '-p' }), /flag|absolute/i, 'a flag like -p is rejected (no node -p code exec)');
  assert.throws(() => makeSlRunner({ cliJs: 'relative/cli.js' }), /absolute/i);
  assert.throws(() => makeSlRunner({ cliJs: join(tmpdir(), 'nope-does-not-exist-xyz.js') }), /real path|resolve/i);
  assert.throws(() => makeSlRunner({ cliJs: NOT_CLI }), /sentinelayer-cli/i, 'an arbitrary JS file (not the CLI package) is rejected');
  const prev = process.env.SL_CLI_JS; delete process.env.SL_CLI_JS;
  assert.throws(() => makeSlRunner({}), /SL_CLI_JS is required/);
  if (prev != null) process.env.SL_CLI_JS = prev;
});

test('rejects non-string args', () => {
  const run = makeSlRunner({ cliJs: CLI, execFile: () => '{}' });
  assert.throws(() => run(['ok', 5]), /string/);
  assert.throws(() => run('nope'), /string/);
});

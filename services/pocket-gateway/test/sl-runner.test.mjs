// sl-runner.test.mjs — the sl invoker must be SHELL-FREE and byte-preserve injection metacharacters (Echo #233114 P0).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeSlRunner } from '../src/sl-runner.mjs';

test('runner dispatches via node + cli.js (never cmd/shell) and byte-preserves metacharacters', () => {
  let seen;
  const run = makeSlRunner({ cliJs: '/abs/sentinelayer-cli.js', execFile: (cmd, args) => { seen = { cmd, args }; return '{}'; } });
  const evil = 'ok & calc.exe | echo %PATH% > x ^ "q" `n`';
  run(['session', 'reply', 'sid', '5', evil, '--agent', 'a']);
  assert.equal(seen.cmd, process.execPath, 'dispatches through node, never a shell');
  assert.equal(seen.args[0], '/abs/sentinelayer-cli.js');
  assert.deepEqual(seen.args.slice(1), ['session', 'reply', 'sid', '5', evil, '--agent', 'a']);
  assert.equal(seen.args[5], evil, 'renderedPreview passed VERBATIM as one argv entry (not shell-interpreted)');
});

test('rejects non-string args', () => {
  const run = makeSlRunner({ cliJs: '/abs/cli.js', execFile: () => '{}' });
  assert.throws(() => run(['ok', 5]), /string/);
  assert.throws(() => run('nope'), /string/);
});

test('Windows without SL_CLI_JS refuses rather than use the injection-prone .cmd shim', () => {
  const run = makeSlRunner({ cliJs: null, execFile: () => { throw new Error('should not exec'); } });
  if (process.platform === 'win32') assert.throws(() => run(['x']), /SL_CLI_JS is required on Windows/);
});

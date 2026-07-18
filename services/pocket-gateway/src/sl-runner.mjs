// sl-runner.mjs — SHELL-FREE sentinelayer-cli invoker (Echo #233114 P0).
// NEVER dispatch via `cmd /c sl` or the `sl.cmd` shim: on Windows cmd RE-PARSES the argument line, so shell
// metacharacters (% & | > < ^ " ) in user-controlled content (e.g. an ActionProposal.renderedPreview) would EXECUTE.
// We invoke `node <sentinelayer-cli.js> ...args` directly through execFile (no shell), which passes every argument
// as one opaque, byte-preserved argv entry — no interpretation, no injection.
import { execFileSync } from 'node:child_process';

/**
 * @param {{ cliJs?: string, execFile?: Function, maxBuffer?: number }} opts
 *   cliJs   absolute path to sentinelayer-cli.js (env SL_CLI_JS). If absent on POSIX, falls back to the `sl` binary
 *           directly (execFile, still no shell). On Windows cliJs is REQUIRED — the sl.cmd shim is shell-parsed.
 *   execFile injectable for tests; defaults to node:child_process execFileSync.
 * @returns {(args: string[]) => string} run(args) -> stdout
 */
export function makeSlRunner(opts = {}) {
  const cliJs = opts.cliJs || process.env.SL_CLI_JS || null;
  const execFile = opts.execFile || execFileSync;
  const maxBuffer = opts.maxBuffer || 64 * 1024 * 1024;
  return function run(args) {
    if (!Array.isArray(args) || args.some((a) => typeof a !== 'string')) throw new Error('sl args must be a string[]');
    if (cliJs) return execFile(process.execPath, [cliJs, ...args], { encoding: 'utf8', maxBuffer });
    if (process.platform === 'win32') throw new Error('SL_CLI_JS is required on Windows (the sl.cmd shim is shell-parsed and injection-prone)');
    return execFile('sl', args, { encoding: 'utf8', maxBuffer }); // POSIX: execFile does NOT spawn a shell
  };
}

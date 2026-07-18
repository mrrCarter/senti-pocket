// sl-runner.mjs — SHELL-FREE, HARDENED sentinelayer-cli invoker (Echo #233114 P0 + #233248 P1).
// NEVER dispatch via `cmd /c sl` / the `sl.cmd` shim: on Windows cmd RE-PARSES the argument line, so shell
// metacharacters in user-controlled content would execute. We spawn `node <sentinelayer-cli.js> ...args` via execFile
// (no shell) with a VALIDATED, absolute, realpath'd CLI entrypoint, a MINIMAL child env, and a bounded timeout.
import { execFileSync } from 'node:child_process';
import { realpathSync, statSync } from 'node:fs';
import { isAbsolute } from 'node:path';

// Minimal env allowlist for the child (do NOT inherit the full parent env / arbitrary secrets). Includes what the
// CLI needs to run + locate its own auth/config, nothing more.
const ENV_ALLOW = ['PATH', 'HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'SystemRoot', 'TEMP', 'TMP', 'TMPDIR', 'LANG', 'SENTINELAYER_TOKEN', 'SENTINELAYER_API', 'SENTINELAYER_HOME', 'NODE_PATH'];
function minimalEnv(src = process.env) {
  const e = {};
  for (const k of ENV_ALLOW) if (src[k] != null) e[k] = src[k];
  return e;
}

/**
 * Validate the CLI entrypoint at construction (boot), not at call time: must be a non-flag, ABSOLUTE path that
 * realpath-resolves to an existing regular file (rejects "-p", relative paths, PATH lookups, directories, missing).
 */
function validateCliJs(cliJs) {
  if (typeof cliJs !== 'string' || !cliJs || cliJs.startsWith('-')) throw new Error('SL_CLI_JS must be an absolute path to sentinelayer-cli.js (not a flag/empty)');
  if (!isAbsolute(cliJs)) throw new Error('SL_CLI_JS must be ABSOLUTE (no PATH lookup / relative resolution)');
  let real;
  try { real = realpathSync(cliJs); } catch { throw new Error('SL_CLI_JS does not resolve to a real path: ' + cliJs); }
  if (!statSync(real).isFile()) throw new Error('SL_CLI_JS is not a regular file: ' + real);
  return real;
}

/**
 * @param {{ cliJs?: string, execFile?: Function, maxBuffer?: number, timeoutMs?: number, requireCli?: boolean }} opts
 *   cliJs      absolute path to sentinelayer-cli.js (env SL_CLI_JS). REQUIRED (no PATH fallback). Validated at boot.
 *   execFile   injectable for tests (defaults execFileSync).
 * @returns {(args: string[]) => string} run(args) -> stdout
 * NOTE: `sl session reply` takes the message as a positional arg, so on a shared host the confirmed renderedPreview is
 * argv-visible to that host's process list. Acceptable for the LOCAL single-operator demo (own machine, not a secret);
 * production posts via the Senti API, not the CLI. Documented residual, not a shell-injection path.
 */
export function makeSlRunner(opts = {}) {
  const rawCliJs = opts.cliJs || process.env.SL_CLI_JS || null;
  if (!rawCliJs) throw new Error('SL_CLI_JS is required (absolute sentinelayer-cli.js path) — no PATH fallback, no sl.cmd shim');
  const cliJs = validateCliJs(rawCliJs); // throws at BOOT on any invalid/untrusted entrypoint
  const execFile = opts.execFile || execFileSync;
  const maxBuffer = opts.maxBuffer || 64 * 1024 * 1024;
  const timeout = opts.timeoutMs || 30_000;
  const env = minimalEnv();
  return function run(args) {
    if (!Array.isArray(args) || args.some((a) => typeof a !== 'string')) throw new Error('sl args must be a string[]');
    return execFile(process.execPath, [cliJs, ...args], { encoding: 'utf8', maxBuffer, timeout, env, windowsHide: true });
  };
}

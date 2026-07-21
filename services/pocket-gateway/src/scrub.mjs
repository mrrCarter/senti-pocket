// scrub.mjs — Relay secret/credential redaction (BEST-EFFORT, defense-in-depth).
//
// HONEST SCOPE (Echo P0 secret-egress): this is a KNOWN-FORMAT regex denylist plus conservative high-entropy
// heuristics. It CANNOT establish that content is secret-free — an arbitrary/natural-language secret (e.g. a
// passphrase like "correct horse battery staple") will pass through unchanged. Therefore callers MUST also:
//   (1) minimize what crosses to the phone (project only needed fields; bound sizes — see extract.mjs/bundle.mjs),
//   (2) run a FINAL egress scrub over every phone-visible string right before signing (bundle.mjs), and
//   (3) treat all residual content as UNTRUSTED.
// Soul invariant: "Never expose credentials or copy unrestricted private room history into fixtures."
// Fail-safe by construction: redaction only ever REMOVES data; it never adds or reveals. Over-redaction is safe.

/**
 * Ordered redaction rules: [regex, label]. Longest/most-specific first so a JWT or private key is not partially
 * eaten by a broader rule; conservative high-entropy catch-alls run LAST.
 */
const RULES = [
  // PEM private keys (multi-line) — must run before generic base64 rules.
  [/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/g, 'private-key'],
  // JWT (three base64url segments).
  [/\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b/g, 'jwt'],
  // Provider / platform token prefixes (prefix + opaque body).
  [/\bsk-[A-Za-z0-9]{12,}\b/g, 'api-key'],               // OpenAI-style secret key
  [/\b(?:sk|rk|pk)_live_[0-9A-Za-z]{12,}\b/g, 'stripe-key'],
  [/\bAIza[0-9A-Za-z_-]{35}\b/g, 'google-api-key'],
  [/\batk_[A-Za-z0-9._-]{8,}\b/g, 'aidenid-token'],      // AIdenID access token
  [/\bslox_[A-Za-z0-9._-]{8,}\b/g, 'sl-exchange-token'],
  [/\bgh[pousr]_[A-Za-z0-9]{16,}\b/g, 'github-token'],
  [/\bAKIA[0-9A-Z]{16}\b/g, 'aws-access-key-id'],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g, 'slack-token'],
  // Authorization: Bearer <token>
  [/\bBearer\s+[A-Za-z0-9._~+/-]{16,}=*/g, 'bearer'],
  // key/secret/password/token = "<value>" assignments (value masked, key kept).
  [/\b((?:api[_-]?key|secret|password|passwd|token|authorization|access[_-]?key|private[_-]?key)\s*[:=]\s*)(["']?)[^\s"']{6,}\2/gi, 'kv-secret'],
  // Conservative high-entropy catch-alls (defense-in-depth; over-redaction is safe). Run LAST.
  [/\b[0-9a-fA-F]{40,}\b/g, 'hex-secret'],               // long hex blob (keys, digests)
  [/\b[A-Za-z0-9_-]{48,}\b/g, 'opaque-token'],           // long opaque base64url-ish blob
];

/**
 * Redact known-format secrets from a single string (best-effort).
 * @param {string} input
 * @returns {{ text: string, redactions: string[] }} scrubbed text + labels of what was removed
 */
export function scrubText(input) {
  if (typeof input !== 'string' || input.length === 0) {
    return { text: input ?? '', redactions: [] };
  }
  let text = input;
  const redactions = [];
  for (const [re, label] of RULES) {
    text = text.replace(re, (m, ...rest) => {
      redactions.push(label);
      // For the kv-secret rule, preserve the "key:" prefix (rest[0]) and only mask the value.
      if (label === 'kv-secret' && typeof rest[0] === 'string') {
        return `${rest[0]}[REDACTED:${label}]`;
      }
      return `[REDACTED:${label}]`;
    });
  }
  return { text, redactions };
}

/**
 * Coerce a Senti export event payload (object or string) to a display string, then scrub it.
 * Prefers a human-readable body field (minimal projection); only falls back to a JSON dump of the whole object
 * when none is present. The JSON dump is scrubbed too, but note the honest scope above: unknown-format secrets survive.
 * @param {unknown} payload
 * @returns {{ text: string, redactions: string[] }}
 */
export function scrubPayload(payload) {
  let raw;
  if (payload == null) raw = '';
  else if (typeof payload === 'string') raw = payload;
  else if (typeof payload === 'object') {
    raw = payload.text ?? payload.body ?? payload.message ?? payload.content ?? JSON.stringify(payload);
  } else raw = String(payload);
  return scrubText(raw);
}

/**
 * Recursively best-effort scrub every STRING leaf of a value (objects + arrays walked, incl. nested fields).
 * Used as the FINAL egress pass over phone-visible bundle content (Echo P0). Returns the scrubbed clone + labels.
 * @param {unknown} v
 * @returns {{ value: unknown, redactions: string[] }}
 */
export function scrubDeep(v) {
  const redactions = [];
  const walk = (x) => {
    if (typeof x === 'string') { const r = scrubText(x); redactions.push(...r.redactions); return r.text; }
    if (Array.isArray(x)) return x.map(walk);
    if (x && typeof x === 'object') { const o = {}; for (const k of Object.keys(x)) o[k] = walk(x[k]); return o; }
    return x;
  };
  return { value: walk(v), redactions };
}

// scrub.mjs — Relay secret/credential redaction.
// Runs on EVERY checkpoint payload before it is placed in a RawEvent that can cross to the phone.
// Soul invariant: "Never expose credentials or copy unrestricted private room history into fixtures."
// Fail-safe by construction: redaction only ever REMOVES data; it never adds or reveals.

/**
 * Ordered redaction rules. Each entry: [regex, label].
 * Labels are generic (no real secrets embedded). Longest/most-specific patterns first so a JWT
 * or private key is not partially eaten by a broader rule.
 */
const RULES = [
  // PEM private keys (multi-line) — must run before generic base64 rules.
  [/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/g, 'private-key'],
  // JWT (three base64url segments).
  [/\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\b/g, 'jwt'],
  // Provider / platform token prefixes (prefix + opaque body).
  [/\bsk-[A-Za-z0-9]{12,}\b/g, 'api-key'],            // OpenAI-style secret key
  [/\batk_[A-Za-z0-9._-]{8,}\b/g, 'aidenid-token'],   // AIdenID access token
  [/\bslox_[A-Za-z0-9._-]{8,}\b/g, 'sl-exchange-token'],
  [/\bgh[pousr]_[A-Za-z0-9]{16,}\b/g, 'github-token'],
  [/\bAKIA[0-9A-Z]{16}\b/g, 'aws-access-key-id'],
  [/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g, 'slack-token'],
  // Authorization: Bearer <token>
  [/\bBearer\s+[A-Za-z0-9._~+/-]{16,}=*/g, 'bearer'],
  // key/secret/password/token = "<value>" assignments.
  [/\b((?:api[_-]?key|secret|password|passwd|token|authorization)\s*[:=]\s*)(["']?)[^\s"']{8,}\2/gi, 'kv-secret'],
];

/**
 * Redact secrets from a single string.
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
 * The export payload shape varies by event type; we prefer the human-readable body field.
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

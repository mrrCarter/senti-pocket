import crypto from "node:crypto";

/** Deterministic canonical JSON: keys sorted, undefined/null/"" dropped. Mirrors the CLI's
 *  stableJson so bundle ids/idempotency keys are reproducible across runs and machines. */
export function canonicalJson(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((v) => canonicalJson(v));
  if (!value || typeof value !== "object") return value;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(value as Record<string, unknown>).sort()) {
    const next = canonicalJson((value as Record<string, unknown>)[key]);
    if (next !== undefined && next !== null && next !== "") out[key] = next;
  }
  return out;
}

export function sha256Hex(value: unknown): string {
  return crypto.createHash("sha256").update(JSON.stringify(canonicalJson(value))).digest("hex");
}

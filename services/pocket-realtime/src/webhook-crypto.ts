import type { RuntimeEnv } from "./env";
import { HttpError, upstreamError } from "./errors";
import { configuredPositiveInteger } from "./validation";

const PUBLIC_KEY_CACHE_SECONDS = 60 * 60;

export async function verifyRealtimeKitSignature(
  env: RuntimeEnv,
  signature: string,
  body: ArrayBuffer,
  ctx: ExecutionContext,
): Promise<boolean> {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(signature) || signature.length > 8_192) {
    throw new HttpError(400, "invalid_signature", "Webhook signature is invalid.");
  }
  let signatureBytes: Uint8Array<ArrayBuffer>;
  try {
    signatureBytes = base64Bytes(signature);
  } catch {
    throw new HttpError(400, "invalid_signature", "Webhook signature is invalid.");
  }
  const publicKeyPem = await fetchPublicKey(env, ctx);
  const spkiBytes = pemBytes(publicKeyPem);
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "spki",
      spkiBytes,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
  } catch {
    throw upstreamError("invalid_webhook_key", "RealtimeKit webhook verification is unavailable.");
  }
  return crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    signatureBytes,
    body,
  );
}

export async function sha256Hex(value: ArrayBuffer): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", value));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function fetchPublicKey(env: RuntimeEnv, ctx: ExecutionContext): Promise<string> {
  const url = publicKeyUrl(env.REALTIMEKIT_WEBHOOK_PUBLIC_KEY_URL);
  const cacheKey = new Request(url, { method: "GET" });
  const cache = await caches.open("realtimekit-webhook-keys-v1");
  const cached = await cache.match(cacheKey);
  if (cached) {
    const pem = await cached.text();
    if (validPem(pem)) return pem;
  }

  const timeoutMs = configuredPositiveInteger(
    env.OUTBOUND_TIMEOUT_MS,
    30_000,
    "OUTBOUND_TIMEOUT_MS",
  );
  let response: Response;
  try {
    response = await fetch(url, {
      method: "GET",
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw upstreamError(
      "webhook_key_unavailable",
      "RealtimeKit webhook verification is unavailable.",
    );
  }
  if (!response.ok) {
    throw upstreamError(
      "webhook_key_unavailable",
      "RealtimeKit webhook verification is unavailable.",
    );
  }
  const bytes = await response.arrayBuffer();
  if (bytes.byteLength > 32 * 1024) {
    throw upstreamError("invalid_webhook_key", "RealtimeKit returned an invalid webhook key.");
  }
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw upstreamError("invalid_webhook_key", "RealtimeKit returned an invalid webhook key.");
  }
  const pem = readPublicKey(payload);
  if (!validPem(pem)) {
    throw upstreamError("invalid_webhook_key", "RealtimeKit returned an invalid webhook key.");
  }
  ctx.waitUntil(
    cache.put(
      cacheKey,
      new Response(pem, {
        headers: {
          "cache-control": `public, max-age=${PUBLIC_KEY_CACHE_SECONDS}`,
          "content-type": "text/plain; charset=utf-8",
        },
      }),
    ),
  );
  return pem;
}

function publicKeyUrl(value: string): string {
  try {
    const url = new URL(value);
    const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
    if (url.protocol !== "https:" && !(local && url.protocol === "http:")) throw new Error();
    if (url.username || url.password) throw new Error();
    return url.toString();
  } catch {
    throw upstreamError(
      "invalid_webhook_key_configuration",
      "RealtimeKit webhook verification is unavailable.",
    );
  }
}

function readPublicKey(value: unknown): string {
  if (!value || typeof value !== "object" || Array.isArray(value)) return "";
  const data = (value as Record<string, unknown>).data;
  if (!data || typeof data !== "object" || Array.isArray(data)) return "";
  const key = (data as Record<string, unknown>).publicKey;
  return typeof key === "string" ? key : "";
}

function validPem(value: string): boolean {
  return (
    value.length >= 128 &&
    value.length <= 16_384 &&
    value.includes("-----BEGIN PUBLIC KEY-----") &&
    value.includes("-----END PUBLIC KEY-----")
  );
}

function pemBytes(value: string): Uint8Array<ArrayBuffer> {
  const clean = value
    .replace(/\\n/g, "")
    .replace(/-----BEGIN PUBLIC KEY-----/g, "")
    .replace(/-----END PUBLIC KEY-----/g, "")
    .replace(/\s+/g, "");
  try {
    return base64Bytes(clean);
  } catch {
    throw upstreamError("invalid_webhook_key", "RealtimeKit returned an invalid webhook key.");
  }
}

function base64Bytes(value: string): Uint8Array<ArrayBuffer> {
  const binary = atob(value);
  const buffer = new ArrayBuffer(binary.length);
  const bytes = new Uint8Array(buffer);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

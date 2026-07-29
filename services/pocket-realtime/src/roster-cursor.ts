import { HttpError } from "./errors";

export const ROSTER_SHARD_COUNT = 16;
export const DEFAULT_ROSTER_PAGE_SIZE = 100;
export const MAX_ROSTER_PAGE_SIZE = 200;
export const ROSTER_CURSOR_LIFETIME_MS = 10 * 60 * 1_000;

const BASE64_URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
const PARTICIPANT_KEY = /^senti_[A-Za-z0-9_-]{43}$/;
const SNAPSHOT_ID = /^[A-Za-z0-9_-]{43}$/;
const OPAQUE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface RosterCursorState {
  version: 1;
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
  snapshotId: string;
  revisions: number[];
  counts: number[];
  shardIndex: number;
  afterParticipantKey: string | null;
  pageIndex: number;
  pageSize: number;
  joinedCount: number;
  expiresAt: number;
}

export function isRosterParticipantKey(value: string): boolean {
  return PARTICIPANT_KEY.test(value);
}

export function rosterShardIndex(participantKey: string): number {
  if (!PARTICIPANT_KEY.test(participantKey)) {
    throw new HttpError(
      503,
      "invalid_roster_identity",
      "The roster identity projection is invalid.",
    );
  }
  const value = BASE64_URL.indexOf(participantKey[6]!);
  if (value < 0) {
    throw new HttpError(
      503,
      "invalid_roster_identity",
      "The roster identity projection is invalid.",
    );
  }
  return value % ROSTER_SHARD_COUNT;
}

export function rosterShardName(roomId: string, shardIndex: number): string {
  if (
    !ROOM_ID.test(roomId) ||
    !Number.isInteger(shardIndex) ||
    shardIndex < 0 ||
    shardIndex >= ROSTER_SHARD_COUNT
  ) {
    throw new HttpError(
      503,
      "invalid_roster_shard",
      "The roster projection shard is invalid.",
    );
  }
  return `roster:v1:${roomId}:${shardIndex}`;
}

export async function rosterSnapshotId(
  roomId: string,
  revisions: readonly number[],
): Promise<string> {
  validateVector(revisions, "revisions");
  if (!ROOM_ID.test(roomId)) throw invalidCursor();
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      `roster-snapshot:v1:${roomId}:${revisions.join(",")}`,
    ),
  );
  return bytesToBase64Url(new Uint8Array(digest));
}

export async function encodeRosterCursor(
  secret: string,
  state: RosterCursorState,
): Promise<string> {
  validateState(state);
  const payload = bytesToBase64Url(
    new TextEncoder().encode(JSON.stringify(state)),
  );
  const signature = await hmac(secret, `roster-cursor:v1:${payload}`);
  return `r1.${payload}.${bytesToBase64Url(signature)}`;
}

export async function decodeRosterCursor(
  secret: string,
  token: string,
  roomId: string,
  nowMs: number,
): Promise<RosterCursorState> {
  const match = /^r1\.([A-Za-z0-9_-]{1,6144})\.([A-Za-z0-9_-]{43})$/.exec(
    token,
  );
  if (!match?.[1] || !match[2]) throw invalidCursor();
  const payload = match[1];
  const signature = base64UrlToArrayBuffer(match[2]);
  const key = await importHmacKey(secret, ["verify"]);
  const valid = await crypto.subtle.verify(
    "HMAC",
    key,
    signature,
    new TextEncoder().encode(`roster-cursor:v1:${payload}`),
  );
  if (!valid) throw invalidCursor();

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(base64UrlToBytes(payload)));
  } catch {
    throw invalidCursor();
  }
  if (!isRecord(decoded)) throw invalidCursor();
  const state = decoded as unknown as RosterCursorState;
  validateState(state);
  if (state.roomId !== roomId || state.expiresAt <= nowMs) {
    throw invalidCursor();
  }
  return state;
}

function validateState(state: RosterCursorState): void {
  if (
    !isRecord(state) ||
    Object.keys(state).length !== 15 ||
    state.version !== 1 ||
    !OPAQUE_ID.test(state.tenantId) ||
    !UUID.test(state.sessionId) ||
    !UUID.test(state.roomEpoch) ||
    !ROOM_ID.test(state.roomId) ||
    !OPAQUE_ID.test(state.providerMeetingId) ||
    !SNAPSHOT_ID.test(state.snapshotId) ||
    !Number.isInteger(state.shardIndex) ||
    state.shardIndex < 0 ||
    state.shardIndex >= ROSTER_SHARD_COUNT ||
    (state.afterParticipantKey !== null &&
      !PARTICIPANT_KEY.test(state.afterParticipantKey)) ||
    !Number.isSafeInteger(state.pageIndex) ||
    state.pageIndex < 0 ||
    !Number.isSafeInteger(state.pageSize) ||
    state.pageSize < 1 ||
    state.pageSize > MAX_ROSTER_PAGE_SIZE ||
    !Number.isSafeInteger(state.joinedCount) ||
    state.joinedCount < 0 ||
    !Number.isSafeInteger(state.expiresAt) ||
    state.expiresAt <= 0
  ) {
    throw invalidCursor();
  }
  validateVector(state.revisions, "revisions");
  validateVector(state.counts, "counts");
  if (
    state.counts.reduce((sum, value) => sum + value, 0) !==
    state.joinedCount
  ) {
    throw invalidCursor();
  }
}

function validateVector(
  vector: readonly number[],
  _field: "revisions" | "counts",
): void {
  if (
    !Array.isArray(vector) ||
    vector.length !== ROSTER_SHARD_COUNT ||
    vector.some(
      (value) =>
        !Number.isSafeInteger(value) ||
        value < 0,
    )
  ) {
    throw invalidCursor();
  }
}

async function hmac(secret: string, value: string): Promise<Uint8Array> {
  const key = await importHmacKey(secret, ["sign"]);
  return new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(value)),
  );
}

async function importHmacKey(
  secret: string,
  usages: KeyUsage[],
): Promise<CryptoKey> {
  if (secret.length < 32) {
    throw new HttpError(
      503,
      "identity_key_not_configured",
      "Roster cursor verification is unavailable.",
    );
  }
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages,
  );
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function base64UrlToBytes(value: string): Uint8Array {
  try {
    const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
    const binary = atob(padded);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    throw invalidCursor();
  }
}

function base64UrlToArrayBuffer(value: string): ArrayBuffer {
  const bytes = base64UrlToBytes(value);
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function invalidCursor(): HttpError {
  return new HttpError(
    422,
    "invalid_roster_cursor",
    "The roster cursor is invalid or expired.",
  );
}

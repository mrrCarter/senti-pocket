import type { SentiMembershipRole, VoiceRole } from "./contracts";
import { HttpError } from "./errors";

export function roleForMembership(
  membershipRole: SentiMembershipRole,
  requestedRole?: VoiceRole,
): VoiceRole {
  const maximum: VoiceRole =
    membershipRole === "owner" || membershipRole === "admin"
      ? "moderator"
      : membershipRole === "contributor"
        ? "speaker"
        : "listener";
  if (!requestedRole) return maximum;
  const rank: Record<VoiceRole, number> = { listener: 0, speaker: 1, moderator: 2 };
  return rank[requestedRole] <= rank[maximum] ? requestedRole : maximum;
}

export async function deriveRoomId(
  secret: string,
  tenantId: string,
  sessionId: string,
  roomEpoch: string,
): Promise<string> {
  return hmacBase64Url(secret, `room:v1:${tenantId}:${sessionId}:${roomEpoch}`);
}

export async function deriveParticipantId(
  secret: string,
  roomId: string,
  humanId: string,
): Promise<string> {
  return `senti_${await hmacBase64Url(secret, `participant:v1:${roomId}:${humanId}`)}`;
}

export function meetingTitle(roomId: string): string {
  return `senti-v1-${roomId}`;
}

export function roomIdFromMeetingTitle(title: unknown): string | null {
  if (typeof title !== "string") return null;
  const match = /^senti-v1-([A-Za-z0-9_-]{43})$/.exec(title);
  return match?.[1] ?? null;
}

async function hmacBase64Url(secret: string, message: string): Promise<string> {
  if (secret.length < 32) {
    throw new HttpError(503, "identity_key_not_configured", "Identity derivation is unavailable.");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return bytesToBase64Url(new Uint8Array(digest));
}

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

import type {
  ModerateRoomRequest,
  RoomRecord,
  VoiceModerationAction,
} from "./contracts";
import { HttpError } from "./errors";

export interface VoiceControlExecutionCommand {
  room: RoomRecord;
  commandId: string;
  controlRevision: number;
  action: VoiceModerationAction;
  targetProviderParticipantId: string;
}

export type VoiceControlExecutionResult =
  | {
      disposition: "unsupported";
      resultCode: "executor_unavailable";
      providerMutationApplied: false;
    }
  | {
      disposition: "applied";
      providerMutationApplied: true;
      providerReceiptId: string;
    };

export interface VoiceControlExecutor {
  execute(
    command: VoiceControlExecutionCommand,
  ): Promise<VoiceControlExecutionResult>;
}

export class UnavailableVoiceControlExecutor implements VoiceControlExecutor {
  async execute(
    _command: VoiceControlExecutionCommand,
  ): Promise<VoiceControlExecutionResult> {
    return {
      disposition: "unsupported",
      resultCode: "executor_unavailable",
      providerMutationApplied: false,
    };
  }
}

interface ModerationFingerprintContext {
  tenantId: string;
  actorPrincipalId: string;
  input: ModerateRoomRequest;
}

export async function moderationFingerprints(
  secret: string,
  context: ModerationFingerprintContext,
): Promise<{ idempotencyHash: string; payloadHash: string }> {
  if (secret.length < 32) {
    throw new HttpError(
      503,
      "identity_key_not_configured",
      "Command identity derivation is unavailable.",
    );
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const scope = JSON.stringify([
    "voice-moderation-idempotency.v1",
    context.tenantId,
    context.input.sessionId,
    context.input.roomEpoch,
    context.input.idempotencyKey,
  ]);
  const payload = JSON.stringify([
    "voice-moderation-command.v1",
    context.tenantId,
    context.input.sessionId,
    context.input.roomEpoch,
    context.actorPrincipalId,
    context.input.commandId,
    context.input.expectedRevision,
    context.input.targetPrincipalId,
    context.input.action,
  ]);
  const [idempotencyHash, payloadHash] = await Promise.all([
    hmacBase64Url(key, scope),
    hmacBase64Url(key, payload),
  ]);
  return { idempotencyHash, payloadHash };
}

async function hmacBase64Url(
  key: CryptoKey,
  message: string,
): Promise<string> {
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message),
  );
  const bytes = new Uint8Array(digest);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

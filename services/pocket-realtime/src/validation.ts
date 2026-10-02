import type {
  JoinRoomRequest,
  OpenRoomRequest,
  RoomUsageRequest,
  TranscriptMode,
  VoiceRole,
} from "./contracts";
import { HttpError } from "./errors";

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const REQUEST_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/;
const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
const DELIVERY_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const EVENT_NAME = /^[A-Za-z][A-Za-z0-9.]{2,79}$/;
const MAX_JSON_BYTES = 8 * 1024;
export const MAX_WEBHOOK_BYTES = 256 * 1024;

export async function readBoundedJson(request: Request): Promise<unknown> {
  const declaredLength = parseDeclaredLength(request);
  if (declaredLength !== null && declaredLength > MAX_JSON_BYTES) {
    throw new HttpError(413, "request_too_large", "Request body is too large.");
  }
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > MAX_JSON_BYTES) {
    throw new HttpError(413, "request_too_large", "Request body is too large.");
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new HttpError(400, "invalid_json", "Request body must be valid JSON.");
  }
}

export function parseOpenRoomRequest(value: unknown): OpenRoomRequest {
  const body = record(value);
  exactKeys(body, ["sessionId", "roomEpoch", "transcriptConsent", "requestId"]);
  const sessionId = uuid(body.sessionId, "sessionId");
  const roomEpoch = uuid(body.roomEpoch, "roomEpoch");
  const requestId = requestIdValue(body.requestId);
  if (body.transcriptConsent !== "granted") {
    throw new HttpError(
      422,
      "transcript_consent_required",
      "Explicit transcript consent is required.",
    );
  }
  return { sessionId, roomEpoch, requestId, transcriptConsent: "granted" };
}

export function parseJoinRoomRequest(value: unknown): JoinRoomRequest {
  const body = record(value);
  exactKeys(body, ["sessionId", "roomEpoch", "requestedRole", "requestId"]);
  const requestedRole = optionalVoiceRole(body.requestedRole);
  return {
    sessionId: uuid(body.sessionId, "sessionId"),
    roomEpoch: uuid(body.roomEpoch, "roomEpoch"),
    requestId: requestIdValue(body.requestId),
    ...(requestedRole ? { requestedRole } : {}),
  };
}

export function parseRoomUsageRequest(value: unknown): RoomUsageRequest {
  const body = record(value);
  exactKeys(body, ["sessionId", "roomEpoch", "requestId"]);
  return {
    sessionId: uuid(body.sessionId, "sessionId"),
    roomEpoch: uuid(body.roomEpoch, "roomEpoch"),
    requestId: requestIdValue(body.requestId),
  };
}

export function parseTranscriptMode(value: string): TranscriptMode {
  if (value === "disabled" || value === "post-meeting") return value;
  throw new HttpError(
    503,
    "invalid_transcription_configuration",
    "Transcription configuration is invalid.",
  );
}

export function requirePostMeetingTranscription(value: string): "post-meeting" {
  if (parseTranscriptMode(value) !== "post-meeting") {
    throw new HttpError(
      503,
      "transcription_not_enabled",
      "Voice rooms require explicitly enabled post-meeting transcription.",
    );
  }
  return "post-meeting";
}

export function validateRoomId(value: string): string {
  if (!ROOM_ID.test(value)) {
    throw new HttpError(400, "invalid_room_id", "Room identifier is invalid.");
  }
  return value;
}

export function validateDeliveryId(value: string | null): string {
  if (!value || !DELIVERY_ID.test(value)) {
    throw new HttpError(400, "invalid_delivery_id", "Webhook delivery identifier is invalid.");
  }
  return value;
}

export function validateEventName(value: unknown): string {
  if (typeof value !== "string" || !EVENT_NAME.test(value)) {
    throw new HttpError(400, "invalid_webhook_event", "Webhook event name is invalid.");
  }
  return value;
}

export function parseDeclaredLength(request: Request): number | null {
  const raw = request.headers.get("content-length");
  if (raw === null) return null;
  if (!/^\d{1,12}$/.test(raw)) {
    throw new HttpError(400, "invalid_content_length", "Content-Length is invalid.");
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) {
    throw new HttpError(400, "invalid_content_length", "Content-Length is invalid.");
  }
  return value;
}

export function configuredPositiveInteger(
  value: string,
  maximum: number,
  fieldName: string,
): number {
  if (!/^\d+$/.test(value)) {
    throw invalidConfiguration(fieldName);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > maximum) {
    throw invalidConfiguration(fieldName);
  }
  return parsed;
}

export function configuredPositiveNumber(
  value: string,
  maximum: number,
  fieldName: string,
): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0 || parsed > maximum) {
    throw invalidConfiguration(fieldName);
  }
  return parsed;
}

function invalidConfiguration(fieldName: string): HttpError {
  return new HttpError(
    503,
    "invalid_runtime_configuration",
    `${fieldName} configuration is invalid.`,
  );
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "invalid_request", "Request body must be a JSON object.");
  }
  return value as Record<string, unknown>;
}

function exactKeys(body: Record<string, unknown>, allowed: string[]): void {
  const allowedKeys = new Set(allowed);
  if (Object.keys(body).some((key) => !allowedKeys.has(key))) {
    throw new HttpError(422, "invalid_request", "Request contains an unknown field.");
  }
}

function uuid(value: unknown, field: string): string {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new HttpError(422, "invalid_request", `${field} must be a UUID.`);
  }
  return value.toLowerCase();
}

function requestIdValue(value: unknown): string {
  if (typeof value !== "string" || !REQUEST_ID.test(value)) {
    throw new HttpError(
      422,
      "invalid_request",
      "requestId must be 8-128 safe characters.",
    );
  }
  return value;
}

function optionalVoiceRole(value: unknown): VoiceRole | undefined {
  if (value === undefined) return undefined;
  if (value === "moderator" || value === "speaker" || value === "listener") return value;
  throw new HttpError(422, "invalid_request", "requestedRole is invalid.");
}

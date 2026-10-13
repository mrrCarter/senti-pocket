import {
  MEDIA_PROVIDER,
  type RoomRecord,
  type TranscriptQueueEnvelope,
  type WebhookEventSummary,
} from "./contracts";
import type { RuntimeEnv } from "./env";
import { HttpError, upstreamError } from "./errors";
import { roomIdFromMeetingTitle } from "./identity";
import {
  MAX_WEBHOOK_BYTES,
  parseDeclaredLength,
  configuredPositiveInteger,
  validateDeliveryId,
  validateEventName,
} from "./validation";
import { sha256Hex, verifyRealtimeKitSignature } from "./webhook-crypto";

const CONTROL_EVENTS = new Set([
  "meeting.started",
  "meeting.ended",
  "meeting.participantJoined",
  "meeting.participantLeft",
  "meeting.transcript",
]);

export async function handleRealtimeKitWebhook(
  request: Request,
  env: RuntimeEnv,
  ctx: ExecutionContext,
): Promise<Response> {
  const declaredLength = parseDeclaredLength(request);
  if (declaredLength !== null && declaredLength > MAX_WEBHOOK_BYTES) {
    throw new HttpError(413, "webhook_too_large", "Webhook body is too large.");
  }
  const signature = request.headers.get("rtk-signature");
  if (!signature) {
    throw new HttpError(400, "missing_signature", "Webhook signature is required.");
  }
  const deliveryId = validateDeliveryId(request.headers.get("rtk-uuid"));
  const webhookId = boundedHeader(request.headers.get("rtk-webhook-id"), 128);
  const rawBody = await request.arrayBuffer();
  if (rawBody.byteLength > MAX_WEBHOOK_BYTES) {
    throw new HttpError(413, "webhook_too_large", "Webhook body is too large.");
  }
  if (!(await verifyRealtimeKitSignature(env, signature, rawBody, ctx))) {
    throw new HttpError(401, "invalid_signature", "Webhook signature is invalid.");
  }

  const payload = parsePayload(rawBody);
  const eventName = validateEventName(payload.event);
  if (!CONTROL_EVENTS.has(eventName)) {
    return accepted("ignored");
  }
  const meeting = record(payload.meeting);
  const roomId = roomIdFromMeetingTitle(meeting.title);
  const providerMeetingId = boundedString(meeting.id, 128);
  if (!roomId || !providerMeetingId) {
    return accepted("unroutable");
  }
  const transcriptProviderSessionId =
    eventName === "meeting.transcript"
      ? requiredProviderSessionId(meeting.sessionId)
      : null;
  const digest = await sha256Hex(rawBody);
  const now = new Date().toISOString();
  const participant = optionalRecord(payload.participant);
  const summary: WebhookEventSummary = {
    deliveryId,
    digest,
    eventName,
    providerMeetingId,
    customParticipantId: boundedString(participant?.customParticipantId, 200),
    participantJoinedAt: isoDate(participant?.joinedAt),
    participantLeftAt: isoDate(participant?.leftAt),
    occurredAt: now,
  };
  const maximum = configuredPositiveInteger(
    env.MAX_CONTROL_REQUESTS_PER_ROOM_PER_DAY,
    100_000,
    "MAX_CONTROL_REQUESTS_PER_ROOM_PER_DAY",
  );
  const room = env.ROOMS.getByName(roomId);
  const acceptance = await room.acceptWebhook(summary, now, maximum);
  if (
    acceptance.disposition === "unknown_room" ||
    acceptance.disposition === "meeting_mismatch"
  ) {
    return accepted(acceptance.disposition);
  }
  if (acceptance.disposition === "digest_conflict") {
    throw new HttpError(
      409,
      "webhook_delivery_conflict",
      "Webhook delivery identifier was reused with different content.",
    );
  }
  if (acceptance.disposition === "over_budget") {
    throw new HttpError(503, "room_budget_exhausted", "Room control budget is exhausted.");
  }
  if (acceptance.disposition === "duplicate") {
    return accepted("duplicate");
  }

  if (eventName === "meeting.transcript") {
    const message = transcriptEnvelope(
      acceptance.room,
      providerMeetingId,
      transcriptProviderSessionId!,
      deliveryId,
      webhookId,
      digest,
      now,
    );
    try {
      await env.TRANSCRIPT_INGEST_QUEUE.send(message, {
        contentType: "json",
      });
    } catch {
      throw upstreamError(
        "transcript_queue_unavailable",
        "Transcript intake is temporarily unavailable.",
      );
    }
  }
  const marked = await room.markWebhookEnqueued(deliveryId, digest, now);
  if (!marked) {
    throw upstreamError(
      "webhook_state_conflict",
      "Webhook intake could not be finalized.",
    );
  }
  return accepted(acceptance.disposition);
}

function transcriptEnvelope(
  room: RoomRecord,
  providerMeetingId: string,
  providerSessionId: string,
  deliveryId: string,
  webhookId: string | null,
  digest: string,
  now: string,
): TranscriptQueueEnvelope {
  return {
    schema: "senti.realtimekit_webhook.v1",
    tenantId: room.tenantId,
    sessionId: room.sessionId,
    roomEpoch: room.roomEpoch,
    roomId: room.roomId,
    provider: MEDIA_PROVIDER,
    providerMeetingId,
    providerSessionId,
    deliveryId,
    webhookId,
    eventName: "meeting.transcript",
    payloadSha256: digest,
    receivedAt: now,
  };
}

function requiredProviderSessionId(value: unknown): string {
  const providerSessionId = boundedString(value, 128);
  if (!providerSessionId) {
    throw new HttpError(
      422,
      "invalid_transcript_webhook",
      "Transcript webhook is missing its provider session identifier.",
    );
  }
  return providerSessionId;
}

function parsePayload(rawBody: ArrayBuffer): Record<string, unknown> {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(rawBody));
    return record(value);
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, "invalid_webhook_json", "Webhook body must be valid JSON.");
  }
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, "invalid_webhook_payload", "Webhook payload is invalid.");
  }
  return value as Record<string, unknown>;
}

function optionalRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function boundedString(value: unknown, maximum: number): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= maximum
    ? value
    : null;
}

function boundedHeader(value: string | null, maximum: number): string | null {
  if (value === null) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(value) || value.length > maximum) {
    throw new HttpError(400, "invalid_webhook_id", "Webhook identifier is invalid.");
  }
  return value;
}

function isoDate(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 64) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : null;
}

function accepted(disposition: string): Response {
  return new Response(JSON.stringify({ accepted: true, disposition }), {
    status: 202,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

import {
  DEGRADED_AGENT_FALLBACK,
  MEDIA_PROVIDER,
  REQUIRED_AGENT_MEDIA_MODE,
  type JoinCredential,
  type RoomDescriptor,
  type RoomRecord,
} from "./contracts";
import type { RuntimeEnv } from "./env";
import { HttpError, upstreamError } from "./errors";
import {
  capabilitiesForRole,
  deriveParticipantId,
  deriveRoomId,
  meetingTitle,
  roleForMembership,
} from "./identity";
import { realtimeKitMediaRoomProvider } from "./media-room-provider";
import { RoomGovernor } from "./room-governor";
import { authenticateMember } from "./senti-client";
import {
  parseJoinRoomRequest,
  parseOpenRoomRequest,
  parseRoomUsageRequest,
  configuredPositiveInteger,
  configuredPositiveNumber,
  readBoundedJson,
  requirePostMeetingTranscription,
} from "./validation";
import { handleRealtimeKitWebhook } from "./webhook";

export { RoomGovernor };

interface RequestContext {
  traceId: string;
  requestId: string;
  requestIdFromHeader: boolean;
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const requestContext = ingressRequestContext(request);
    try {
      const url = new URL(request.url);
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json(
          {
            status: "ok",
            service: "senti-pocket-realtime",
            mediaProvider: MEDIA_PROVIDER,
            transcriptionConfigured: env.TRANSCRIPTION_MODE === "post-meeting",
          },
          200,
          requestContext.traceId,
          requestContext.requestId,
        );
      }
      if (request.method === "POST" && url.pathname === "/v1/voice-rooms/open") {
        return await openRoom(request, env, requestContext);
      }
      if (request.method === "POST" && url.pathname === "/v1/voice-rooms/join") {
        return await joinRoom(request, env, requestContext);
      }
      if (request.method === "POST" && url.pathname === "/v1/voice-rooms/usage") {
        return await roomUsage(request, env, requestContext);
      }
      if (
        request.method === "POST" &&
        url.pathname === "/v1/realtimekit/webhooks"
      ) {
        const response = await handleRealtimeKitWebhook(request, env, ctx);
        response.headers.set("x-trace-id", requestContext.traceId);
        response.headers.set("x-request-id", requestContext.requestId);
        return response;
      }
      return errorResponse(
        new HttpError(404, "not_found", "Not found."),
        requestContext.traceId,
        requestContext.requestId,
      );
    } catch (error) {
      return errorResponse(
        error,
        requestContext.traceId,
        requestContext.requestId,
      );
    }
  },
} satisfies ExportedHandler<RuntimeEnv>;

async function openRoom(
  request: Request,
  env: RuntimeEnv,
  requestContext: RequestContext,
): Promise<Response> {
  const input = parseOpenRoomRequest(await readBoundedJson(request));
  adoptBodyRequestId(requestContext, input.requestId);
  const { traceId } = requestContext;
  const member = await authenticateMember(request, input.sessionId, env);
  if (member.membershipRole !== "owner" && member.membershipRole !== "admin") {
    throw new HttpError(403, "room_open_forbidden", "Only a session owner or admin can open a room.");
  }
  const transcriptMode = requirePostMeetingTranscription(env.TRANSCRIPTION_MODE);
  const provider = realtimeKitMediaRoomProvider(env);
  const roomId = await deriveRoomId(
    env.ROOM_KEY_HMAC_SECRET,
    member.tenantId,
    input.sessionId,
    input.roomEpoch,
  );
  const governor = env.ROOMS.getByName(roomId);
  const now = new Date().toISOString();
  const maximum = dailyMaximum(env);
  const reservation = await governor.reserveProvision(
    member.tenantId,
    input.sessionId,
    input.roomEpoch,
    roomId,
    transcriptMode,
    now,
    maximum,
  );
  if (reservation.disposition === "ready") {
    return json(
      {
        requestId: input.requestId,
        room: descriptor(reservation.room),
      },
      200,
      traceId,
      input.requestId,
    );
  }
  if (reservation.disposition === "busy") {
    throw new HttpError(409, "room_provisioning", "Room provisioning is already in progress.");
  }
  if (reservation.disposition === "ended") {
    throw new HttpError(409, "room_epoch_ended", "This room epoch has already ended.");
  }
  if (reservation.disposition === "identity_mismatch") {
    throw upstreamError(
      "room_identity_conflict",
      "Voice room identity could not be reconciled.",
    );
  }
  if (reservation.disposition === "over_budget") {
    throw new HttpError(429, "room_budget_exhausted", "Room control budget is exhausted.");
  }

  let providerMeeting: { id: string };
  try {
    providerMeeting = await provider.createRoom(meetingTitle(roomId));
  } catch (error) {
    await governor.releaseProvision(reservation.fence, new Date().toISOString());
    throw error;
  }
  const completed = await governor.completeProvision(
    reservation.fence,
    providerMeeting.id,
    new Date().toISOString(),
  );
  if (!completed) {
    try {
      await provider.deactivateRoom(providerMeeting.id);
    } catch {
      console.error(
        JSON.stringify({
          event: "room_provision_compensation_failed",
          traceId,
          providerMeetingId: providerMeeting.id,
        }),
      );
    }
    throw upstreamError("room_provision_conflict", "Room provisioning could not be committed.");
  }
  return json(
    {
      requestId: input.requestId,
      room: descriptor(completed),
    },
    201,
    traceId,
    input.requestId,
  );
}

async function joinRoom(
  request: Request,
  env: RuntimeEnv,
  requestContext: RequestContext,
): Promise<Response> {
  const input = parseJoinRoomRequest(await readBoundedJson(request));
  adoptBodyRequestId(requestContext, input.requestId);
  const { traceId } = requestContext;
  const member = await authenticateMember(request, input.sessionId, env);
  const role = roleForMembership(member.membershipRole, input.requestedRole);
  const provider = realtimeKitMediaRoomProvider(env);
  const roomId = await deriveRoomId(
    env.ROOM_KEY_HMAC_SECRET,
    member.tenantId,
    input.sessionId,
    input.roomEpoch,
  );
  const participantKey = await deriveParticipantId(
    env.IDENTITY_HMAC_SECRET,
    roomId,
    member.humanId,
  );
  const governor = env.ROOMS.getByName(roomId);
  const maximum = dailyMaximum(env);
  const room = await governor.getRoom(
    member.tenantId,
    input.sessionId,
    input.roomEpoch,
    roomId,
  );
  if (
    !room ||
    room.tenantId !== member.tenantId ||
    room.sessionId !== input.sessionId ||
    room.roomEpoch !== input.roomEpoch
  ) {
    throw new HttpError(404, "room_not_ready", "Voice room is not ready.");
  }
  const reservation = await governor.reserveAdmission(
    participantKey,
    role,
    new Date().toISOString(),
    maximum,
  );
  if (reservation.disposition === "busy") {
    throw new HttpError(409, "join_in_progress", "Participant admission is already in progress.");
  }
  if (reservation.disposition === "room_not_ready") {
    throw new HttpError(404, "room_not_ready", "Voice room is not ready.");
  }
  if (reservation.disposition === "over_budget") {
    throw new HttpError(429, "room_budget_exhausted", "Room control budget is exhausted.");
  }

  let participant: { id: string; token: string };
  try {
    if (reservation.disposition === "create") {
      participant = await provider.addParticipant(
        room.providerMeetingId,
        participantKey,
        member.displayName,
        role,
      );
    } else if (reservation.disposition === "update") {
      if (!reservation.providerParticipantId) throw new Error("Missing participant.");
      participant = await provider.updateParticipantRoleAndRefresh(
        room.providerMeetingId,
        reservation.providerParticipantId,
        member.displayName,
        role,
      );
    } else {
      if (!reservation.providerParticipantId) throw new Error("Missing participant.");
      participant = await provider.refreshParticipant(
        room.providerMeetingId,
        reservation.providerParticipantId,
      );
    }
  } catch (error) {
    await governor.releaseAdmission(
      participantKey,
      reservation.fence,
      new Date().toISOString(),
    );
    if (error instanceof HttpError) throw error;
    throw upstreamError("participant_admission_failed", "Participant admission failed.");
  }
  const committed = await governor.completeAdmission(
    participantKey,
    reservation.fence,
    participant.id,
    new Date().toISOString(),
  );
  if (!committed) {
    throw upstreamError("participant_admission_conflict", "Participant admission could not be committed.");
  }

  const issuedAt = new Date();
  const credential: JoinCredential = {
    room: descriptor(room),
    role,
    principalId: member.humanId,
    participantId: participant.id,
    providerCorrelationId: participantKey,
    authToken: participant.token,
    issuedAt: issuedAt.toISOString(),
    clientDiscardAfter: new Date(
      issuedAt.getTime() + 5 * 60 * 1_000,
    ).toISOString(),
    providerScope: "single-participant-single-meeting",
    providerExpiry: "time-bound-undisclosed",
    controlRevision: 0,
    capabilities: capabilitiesForRole(role),
  };
  return json(
    {
      requestId: input.requestId,
      credential,
    },
    200,
    traceId,
    input.requestId,
  );
}

async function roomUsage(
  request: Request,
  env: RuntimeEnv,
  requestContext: RequestContext,
): Promise<Response> {
  const input = parseRoomUsageRequest(await readBoundedJson(request));
  adoptBodyRequestId(requestContext, input.requestId);
  const { traceId } = requestContext;
  const member = await authenticateMember(request, input.sessionId, env);
  if (member.membershipRole !== "owner" && member.membershipRole !== "admin") {
    throw new HttpError(
      403,
      "room_usage_forbidden",
      "Only a session owner or admin can view room usage.",
    );
  }
  const roomId = await deriveRoomId(
    env.ROOM_KEY_HMAC_SECRET,
    member.tenantId,
    input.sessionId,
    input.roomEpoch,
  );
  const result = await env.ROOMS.getByName(roomId).usageSnapshot(
    new Date().toISOString(),
    dailyMaximum(env),
    configuredPositiveNumber(
      env.TRANSCRIPTION_NEURONS_PER_AUDIO_MINUTE,
      1_000_000,
      "TRANSCRIPTION_NEURONS_PER_AUDIO_MINUTE",
    ),
  );
  if (result.disposition === "over_budget") {
    throw new HttpError(429, "room_budget_exhausted", "Room control budget is exhausted.");
  }
  if (result.disposition === "room_not_ready") {
    throw new HttpError(404, "room_not_ready", "Voice room is not ready.");
  }
  if (
    result.room.tenantId !== member.tenantId ||
    result.room.sessionId !== input.sessionId ||
    result.room.roomEpoch !== input.roomEpoch
  ) {
    throw new HttpError(404, "room_not_ready", "Voice room is not ready.");
  }
  return json(
    {
      requestId: input.requestId,
      room: descriptor(result.room),
      usage: result.usage,
    },
    200,
    traceId,
    input.requestId,
  );
}

function descriptor(room: RoomRecord): RoomDescriptor {
  return {
    tenantId: room.tenantId,
    roomId: room.roomId,
    provider: MEDIA_PROVIDER,
    providerMeetingId: room.providerMeetingId,
    sessionId: room.sessionId,
    roomEpoch: room.roomEpoch,
    transcriptMode: "post-meeting",
    requiredAgentMediaMode: REQUIRED_AGENT_MEDIA_MODE,
    agentMediaStatus: "unsupported-pending-spike",
    degradedAgentFallback: DEGRADED_AGENT_FALLBACK,
  };
}

function dailyMaximum(env: RuntimeEnv): number {
  return configuredPositiveInteger(
    env.MAX_CONTROL_REQUESTS_PER_ROOM_PER_DAY,
    100_000,
    "MAX_CONTROL_REQUESTS_PER_ROOM_PER_DAY",
  );
}

function json(
  body: unknown,
  status: number,
  traceId: string,
  requestId: string,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "x-trace-id": traceId,
      "x-request-id": requestId,
    },
  });
}

function errorResponse(error: unknown, traceId: string, requestId: string): Response {
  const httpError =
    error instanceof HttpError
      ? error
      : new HttpError(500, "internal_error", "An internal error occurred.");
  console.error(
    JSON.stringify({
      event: "request_failed",
      traceId,
      status: httpError.status,
      code: httpError.code,
    }),
  );
  return json(
    {
      error: {
        code: canonicalVoiceCode(httpError),
        message: httpError.message,
        requestId,
        recoverable: isRecoverable(httpError),
        retryAfterMs: retryAfterMs(httpError),
      },
    },
    httpError.status,
    traceId,
    requestId,
  );
}

function ingressRequestContext(request: Request): RequestContext {
  const traceId = crypto.randomUUID().replace(/-/g, "");
  const supplied = request.headers.get("x-request-id");
  const valid = Boolean(
    supplied && /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/.test(supplied),
  );
  return {
    traceId,
    requestId: valid && supplied ? supplied : `req_${traceId}`,
    requestIdFromHeader: valid,
  };
}

function adoptBodyRequestId(
  requestContext: RequestContext,
  bodyRequestId: string,
): void {
  if (
    requestContext.requestIdFromHeader &&
    requestContext.requestId !== bodyRequestId
  ) {
    throw new HttpError(
      422,
      "request_id_mismatch",
      "Request identifiers do not match.",
    );
  }
  requestContext.requestId = bodyRequestId;
}

function canonicalVoiceCode(error: HttpError): string {
  if (error.code === "room_epoch_ended") return "VOICE_ROOM_ENDED";
  if (error.code === "room_budget_exhausted") {
    return "VOICE_ENTITLEMENT_EXCEEDED";
  }
  if (error.code.includes("transcript_queue")) return "VOICE_TRANSCRIPT_DEGRADED";
  if (error.status === 400 || error.status === 413 || error.status === 422) {
    return "VOICE_BAD_REQUEST";
  }
  if (error.status === 401) return "VOICE_NOT_AUTHENTICATED";
  if (error.status === 403) return "VOICE_JOIN_NOT_AUTHORIZED";
  if (error.status === 404) return "VOICE_ROOM_NOT_FOUND";
  if (error.status === 409) return "VOICE_CONTROL_CONFLICT";
  if (error.status === 429) return "VOICE_ENTITLEMENT_EXCEEDED";
  if (error.status === 503) return "VOICE_PROVIDER_UNAVAILABLE";
  return "VOICE_INTERNAL";
}

function isRecoverable(error: HttpError): boolean {
  return error.status === 409 || error.status === 429 || error.status >= 500;
}

function retryAfterMs(error: HttpError): number | null {
  if (error.status === 409) return 250;
  if (error.status === 429) return 60_000;
  if (error.status >= 500) return 1_000;
  return null;
}

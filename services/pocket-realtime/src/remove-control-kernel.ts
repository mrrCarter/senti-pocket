import type { ModerationCommandRecord } from "./contracts";
import type {
  ModerationExecutionReservation,
  RemoveAttemptReservation,
} from "./room-governor";

export interface FreshVoiceControlAuthorizationRequest {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  actorPrincipalId: string;
  targetPrincipalId: string;
  action: "remove";
  commandId: string;
  controlRevision: number;
}

export type FreshVoiceControlAuthorization =
  | { disposition: "authorized"; validUntil: string }
  | { disposition: "denied" }
  | { disposition: "unavailable" };

export interface FreshVoiceControlAuthorizer {
  authorize(
    request: FreshVoiceControlAuthorizationRequest,
  ): Promise<FreshVoiceControlAuthorization>;
}

export interface PeerExactRemoveRequest {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
  targetProviderParticipantId: string;
  targetParticipantKey: string;
  targetProviderSessionId: string;
  targetPeerId: string;
  attemptId: string;
}

/**
 * A production adapter must refuse the request unless it can prove that its
 * preflight and mutation apply to the exact peer generation in this request.
 * RealtimeKit's currently reviewed backend kick surface cannot eliminate the
 * custom-ID preflight/kick TOCTOU window, so no live implementation exists.
 */
export type PeerExactRemoveResult =
  | { disposition: "request_accepted" }
  | { disposition: "already_absent" }
  | { disposition: "peer_mismatch" }
  | { disposition: "unavailable" };

export interface PeerExactRemoveProvider {
  ensureAbsent(request: PeerExactRemoveRequest): Promise<PeerExactRemoveResult>;
}

export interface RemoveKernelGovernor {
  beginRemoveAttempt(
    commandId: string,
    fence: string,
    authorizationValidUntil: string,
    now: string,
  ): Promise<RemoveAttemptReservation>;
  markRemovePendingObservation(
    commandId: string,
    fence: string,
    attemptId: string,
    now: string,
  ): Promise<ModerationCommandRecord | null>;
  finalizeRemoveDesiredStateObserved(
    commandId: string,
    fence: string,
    attemptId: string,
    resultCode:
      | "REMOVE_LEAVE_OBSERVED"
      | "REMOVE_ALREADY_ABSENT_OBSERVED",
    providerRequestAccepted: boolean,
    now: string,
  ): Promise<ModerationCommandRecord | null>;
  finalizeRemoveConflict(
    commandId: string,
    fence: string,
    attemptId: string | null,
    now: string,
  ): Promise<ModerationCommandRecord | null>;
  releaseModerationExecution(
    commandId: string,
    fence: string,
  ): Promise<boolean>;
}

export type RemoveKernelOutcome =
  | { disposition: "pending_observation"; command: ModerationCommandRecord }
  | { disposition: "desired_state_observed"; command: ModerationCommandRecord }
  | { disposition: "conflict"; command: ModerationCommandRecord }
  | {
      disposition:
        | "authorization_unavailable"
        | "authorization_expired"
        | "provider_unavailable"
        | "stale_fence";
    };

export async function executeRemoveKernel(
  reservation: Extract<
    ModerationExecutionReservation,
    { disposition: "execute" }
  >,
  governor: RemoveKernelGovernor,
  authorizer: FreshVoiceControlAuthorizer,
  provider: PeerExactRemoveProvider,
  now: string,
): Promise<RemoveKernelOutcome> {
  if (
    reservation.command.action !== "remove" ||
    !reservation.targetProviderSessionId ||
    !reservation.targetPeerId
  ) {
    await governor.releaseModerationExecution(
      reservation.command.commandId,
      reservation.fence,
    );
    return { disposition: "stale_fence" };
  }

  const authorization = await authorizer.authorize({
    tenantId: reservation.room.tenantId,
    sessionId: reservation.room.sessionId,
    roomEpoch: reservation.room.roomEpoch,
    actorPrincipalId: reservation.actorPrincipalId,
    targetPrincipalId: reservation.command.targetPrincipalId,
    action: "remove",
    commandId: reservation.command.commandId,
    controlRevision: reservation.command.controlRevision,
  });
  if (authorization.disposition === "unavailable") {
    await governor.releaseModerationExecution(
      reservation.command.commandId,
      reservation.fence,
    );
    return { disposition: "authorization_unavailable" };
  }
  if (authorization.disposition === "denied") {
    const command = await governor.finalizeRemoveConflict(
      reservation.command.commandId,
      reservation.fence,
      null,
      now,
    );
    return commandOutcome(command);
  }
  if (!futureIso(authorization.validUntil, now)) {
    await governor.releaseModerationExecution(
      reservation.command.commandId,
      reservation.fence,
    );
    return { disposition: "authorization_expired" };
  }

  const attempt = await governor.beginRemoveAttempt(
    reservation.command.commandId,
    reservation.fence,
    authorization.validUntil,
    now,
  );
  if (attempt.disposition === "authorization_expired") {
    await governor.releaseModerationExecution(
      reservation.command.commandId,
      reservation.fence,
    );
    return { disposition: "authorization_expired" };
  }
  if (attempt.disposition === "invalid") {
    return { disposition: "stale_fence" };
  }

  let result: PeerExactRemoveResult;
  try {
    result = await provider.ensureAbsent(providerRequest(reservation, attempt));
  } catch (error) {
    await governor.releaseModerationExecution(
      reservation.command.commandId,
      reservation.fence,
    );
    throw error;
  }

  if (result.disposition === "unavailable") {
    await governor.releaseModerationExecution(
      reservation.command.commandId,
      reservation.fence,
    );
    return { disposition: "provider_unavailable" };
  }
  if (result.disposition === "peer_mismatch") {
    const command = await governor.finalizeRemoveConflict(
      reservation.command.commandId,
      reservation.fence,
      attempt.attemptId,
      now,
    );
    return commandOutcome(command);
  }
  if (result.disposition === "already_absent") {
    const command = await governor.finalizeRemoveDesiredStateObserved(
      reservation.command.commandId,
      reservation.fence,
      attempt.attemptId,
      "REMOVE_ALREADY_ABSENT_OBSERVED",
      false,
      now,
    );
    return commandOutcome(command);
  }

  const command = await governor.markRemovePendingObservation(
    reservation.command.commandId,
    reservation.fence,
    attempt.attemptId,
    now,
  );
  return commandOutcome(command);
}

function providerRequest(
  reservation: Extract<
    ModerationExecutionReservation,
    { disposition: "execute" }
  >,
  attempt: Extract<RemoveAttemptReservation, { disposition: "ready" }>,
): PeerExactRemoveRequest {
  return {
    tenantId: reservation.room.tenantId,
    sessionId: reservation.room.sessionId,
    roomEpoch: reservation.room.roomEpoch,
    roomId: reservation.room.roomId,
    providerMeetingId: reservation.room.providerMeetingId,
    targetProviderParticipantId:
      reservation.targetProviderParticipantId,
    targetParticipantKey: reservation.targetParticipantKey,
    targetProviderSessionId: reservation.targetProviderSessionId!,
    targetPeerId: reservation.targetPeerId!,
    attemptId: attempt.attemptId,
  };
}

function futureIso(candidate: string, now: string): boolean {
  const candidateMs = Date.parse(candidate);
  const nowMs = Date.parse(now);
  return (
    Number.isFinite(candidateMs) &&
    Number.isFinite(nowMs) &&
    candidateMs > nowMs
  );
}

function commandOutcome(
  command: ModerationCommandRecord | null,
): RemoveKernelOutcome {
  if (!command) return { disposition: "stale_fence" };
  if (command.status === "desired_state_observed") {
    return { disposition: "desired_state_observed", command };
  }
  if (command.status === "conflict") {
    return { disposition: "conflict", command };
  }
  if (command.status === "pending_observation") {
    return { disposition: "pending_observation", command };
  }
  return { disposition: "stale_fence" };
}

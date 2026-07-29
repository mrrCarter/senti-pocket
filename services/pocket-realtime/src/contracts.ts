export const MEDIA_PROVIDER = "cloudflare-realtimekit" as const;
export const REQUIRED_AGENT_MEDIA_MODE = "shared-room-track" as const;
export const DEGRADED_AGENT_FALLBACK = "edge-text-client-tts" as const;
export const VOICE_CONTROL_QUEUE_SCHEMA =
  "senti.voice_control.command.v1" as const;

export type SentiMembershipRole = "owner" | "admin" | "contributor" | "viewer";
export type VoiceRole = "moderator" | "speaker" | "listener";
export type VoiceModerationAction =
  | "promote"
  | "demote"
  | "mute"
  | "remove"
  | "deny_publish"
  | "allow_publish";
export type TranscriptConsent = "granted";
export type TranscriptMode = "disabled" | "post-meeting";
export type RoomLifecycle = "provisioning" | "ready" | "ended";

export interface OpenRoomRequest {
  sessionId: string;
  roomEpoch: string;
  transcriptConsent: TranscriptConsent;
  requestId: string;
}

export interface JoinRoomRequest {
  sessionId: string;
  roomEpoch: string;
  requestedRole?: VoiceRole;
  requestId: string;
}

export interface RoomUsageRequest {
  sessionId: string;
  roomEpoch: string;
  requestId: string;
}

export interface ModerateRoomRequest {
  sessionId: string;
  roomEpoch: string;
  requestId: string;
  commandId: string;
  idempotencyKey: string;
  expectedRevision: number;
  targetPrincipalId: string;
  action: VoiceModerationAction;
}

export interface AuthenticatedMember {
  tenantId: string;
  humanId: string;
  displayName: string;
  membershipRole: SentiMembershipRole;
}

export interface RoomDescriptor {
  tenantId: string;
  roomId: string;
  provider: typeof MEDIA_PROVIDER;
  providerMeetingId: string;
  sessionId: string;
  roomEpoch: string;
  controlRevision: number;
  transcriptMode: "post-meeting";
  requiredAgentMediaMode: typeof REQUIRED_AGENT_MEDIA_MODE;
  agentMediaStatus: "unsupported-pending-spike";
  degradedAgentFallback: typeof DEGRADED_AGENT_FALLBACK;
}

export interface JoinCredential {
  room: RoomDescriptor;
  role: VoiceRole;
  principalId: string;
  participantId: string;
  providerCorrelationId: string;
  authToken: string;
  issuedAt: string;
  clientDiscardAfter: string;
  providerScope: "single-participant-single-meeting";
  providerExpiry: "time-bound-undisclosed";
  controlRevision: number;
  capabilities: {
    canPublishAudio: boolean;
    canRaiseHand: boolean;
    canCancelHandRaise: boolean;
    moderationActions: VoiceModerationAction[];
  };
}

export interface TranscriptQueueEnvelope {
  schema: "senti.realtimekit_webhook.v1";
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  provider: typeof MEDIA_PROVIDER;
  providerMeetingId: string;
  providerSessionId: string | null;
  deliveryId: string;
  webhookId: string | null;
  eventName: string;
  payloadSha256: string;
  receivedAt: string;
}

export interface VoiceControlQueueEnvelope {
  schemaVersion: typeof VOICE_CONTROL_QUEUE_SCHEMA;
  roomId: string;
  commandId: string;
  controlRevision: number;
}

export interface RoomUsageSnapshot {
  usageDay: string;
  controlRequests: number;
  completedParticipantMs: number;
  completedParticipantMinutes: number;
  transcriptionNeuronsEstimate: number;
  estimateBasis: "completed-participant-presence";
  billingTruth: false;
}

export interface ModerationCommandRecord {
  commandId: string;
  action: VoiceModerationAction;
  targetPrincipalId: string;
  controlRevision: number;
  status:
    | "pending"
    | "executing"
    | "pending_observation"
    | "desired_state_observed"
    | "conflict"
    | "unsupported";
  providerRequestAccepted: boolean;
  providerStateObserved: boolean;
  causalityProven: false;
  /**
   * Legacy non-mutation field. It remains present and false only while work is
   * pending or definitively unsupported. Observation and conflict records omit
   * it because neither proves whether a provider mutation occurred.
   */
  providerMutationApplied?: false;
  resultCode:
    | "executor_unavailable"
    | "queue_delivery_exhausted"
    | "REMOVE_LEAVE_OBSERVED"
    | "REMOVE_ALREADY_ABSENT_OBSERVED"
    | "VOICE_CONTROL_CONFLICT"
    | null;
  createdAt: string;
  finalizedAt: string | null;
}

export interface RoomRecord {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
  lifecycle: RoomLifecycle;
  controlRevision: number;
  transcriptMode: "post-meeting";
  createdAt: string;
  updatedAt: string;
}

export interface WebhookEventSummary {
  deliveryId: string;
  digest: string;
  eventName: string;
  providerMeetingId: string;
  providerSessionId: string | null;
  peerId: string | null;
  customParticipantId: string | null;
  participantJoinedAt: string | null;
  participantLeftAt: string | null;
  occurredAt: string;
}

export type WebhookAcceptance =
  | { disposition: "new"; room: RoomRecord }
  | { disposition: "retry"; room: RoomRecord }
  | { disposition: "duplicate"; room: RoomRecord }
  | { disposition: "unknown_room" }
  | { disposition: "meeting_mismatch" }
  | { disposition: "digest_conflict" }
  | { disposition: "over_budget" };

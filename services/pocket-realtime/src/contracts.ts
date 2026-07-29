export const MEDIA_PROVIDER = "cloudflare-realtimekit" as const;
export const REQUIRED_AGENT_MEDIA_MODE = "shared-room-track" as const;
export const DEGRADED_AGENT_FALLBACK = "edge-text-client-tts" as const;

export type SentiMembershipRole = "owner" | "admin" | "contributor" | "viewer";
export type VoiceRole = "moderator" | "speaker" | "listener";
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
  transcriptMode: "post-meeting";
  requiredAgentMediaMode: typeof REQUIRED_AGENT_MEDIA_MODE;
  agentMediaStatus: "unsupported-pending-spike";
  degradedAgentFallback: typeof DEGRADED_AGENT_FALLBACK;
}

export interface JoinCredential {
  room: RoomDescriptor;
  role: VoiceRole;
  participantId: string;
  authToken: string;
  issuedAt: string;
  clientDiscardAfter: string;
  providerScope: "single-participant-single-meeting";
  providerExpiry: "time-bound-undisclosed";
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

export interface RoomUsageSnapshot {
  usageDay: string;
  controlRequests: number;
  completedParticipantMs: number;
  completedParticipantMinutes: number;
  transcriptionNeuronsEstimate: number;
  estimateBasis: "completed-participant-presence";
  billingTruth: false;
}

export interface RoomRecord {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
  lifecycle: RoomLifecycle;
  transcriptMode: "post-meeting";
  createdAt: string;
  updatedAt: string;
}

export interface WebhookEventSummary {
  deliveryId: string;
  digest: string;
  eventName: string;
  providerMeetingId: string;
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

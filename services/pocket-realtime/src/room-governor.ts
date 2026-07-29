import { DurableObject } from "cloudflare:workers";
import type {
  ModerationCommandRecord,
  RoomRecord,
  RoomUsageSnapshot,
  SentiMembershipRole,
  VoiceModerationAction,
  VoiceRole,
  WebhookAcceptance,
  WebhookEventSummary,
} from "./contracts";
import type { RuntimeEnv } from "./env";

const PROVISION_LEASE_MS = 30_000;
const ADMISSION_LEASE_MS = 15_000;
const COMMAND_LEASE_MS = 15_000;
const COMMAND_RETENTION_MS = 8 * 24 * 60 * 60 * 1_000;
const MAX_COMMANDS = 4_096;
const DELIVERY_RETENTION_MS = 8 * 24 * 60 * 60 * 1_000;
const MAX_DELIVERIES = 2_048;

export type ProvisionReservation =
  | { disposition: "acquired"; fence: string }
  | { disposition: "ready"; room: RoomRecord }
  | { disposition: "busy" }
  | { disposition: "ended" }
  | { disposition: "identity_mismatch" }
  | { disposition: "over_budget" };

export type AdmissionReservation =
  | {
      disposition: "create";
      fence: string;
      providerParticipantId: string | null;
    }
  | {
      disposition: "refresh";
      fence: string;
      providerParticipantId: string;
    }
  | {
      disposition: "update";
      fence: string;
      providerParticipantId: string;
    }
  | { disposition: "busy" }
  | { disposition: "room_not_ready" }
  | { disposition: "identity_mismatch" }
  | { disposition: "over_budget" };

export interface ModerationReservationInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  actorPrincipalId: string;
  actorMembershipRole: SentiMembershipRole;
  targetPrincipalId: string;
  action: VoiceModerationAction;
  commandId: string;
  idempotencyHash: string;
  payloadHash: string;
  expectedRevision: number;
  now: string;
  maxDailyRequests: number;
}

export type ModerationReservation =
  | {
      disposition: "execute";
      fence: string;
      room: RoomRecord;
      command: ModerationCommandRecord;
      targetProviderParticipantId: string;
    }
  | {
      disposition: "replay" | "busy";
      command: ModerationCommandRecord;
    }
  | {
      disposition: "revision_conflict";
      currentRevision: number;
    }
  | { disposition: "idempotency_conflict"; currentRevision: number }
  | { disposition: "not_authorized"; currentRevision: number }
  | { disposition: "target_not_found"; currentRevision: number }
  | { disposition: "room_not_ready"; currentRevision: number }
  | { disposition: "identity_mismatch"; currentRevision: number }
  | { disposition: "over_budget"; currentRevision: number }
  | { disposition: "command_capacity"; currentRevision: number };

export type UsageResult =
  | { disposition: "ok"; room: RoomRecord; usage: RoomUsageSnapshot }
  | { disposition: "room_not_ready" }
  | { disposition: "over_budget" };

interface RoomRow {
  [key: string]: SqlStorageValue;
  tenant_id: string;
  senti_session_id: string;
  room_epoch: string;
  room_id: string;
  provider_meeting_id: string | null;
  lifecycle: "provisioning" | "ready" | "ended";
  provision_fence: string | null;
  provision_lease_until: number | null;
  control_revision: number;
  transcript_mode: "post-meeting";
  created_at: string;
  updated_at: string;
}

interface AdmissionRow {
  [key: string]: SqlStorageValue;
  participant_key: string;
  principal_id: string | null;
  membership_role: SentiMembershipRole | null;
  role: VoiceRole | null;
  pending_role: VoiceRole | null;
  provider_participant_id: string | null;
  state: "provisioning" | "active";
  fence: string | null;
  lease_until: number | null;
}

interface ModerationCommandRow {
  [key: string]: SqlStorageValue;
  command_id: string;
  idempotency_hash: string;
  payload_hash: string;
  actor_principal_id: string;
  target_principal_id: string;
  target_participant_key: string;
  provider_participant_id: string;
  action: VoiceModerationAction;
  expected_revision: number;
  result_revision: number;
  state: "pending" | "unsupported";
  execution_fence: string | null;
  execution_lease_until: number | null;
  result_code: "executor_unavailable" | null;
  provider_mutation_applied: 0;
  created_at: string;
  finalized_at: string | null;
}

interface DeliveryRow {
  [key: string]: SqlStorageValue;
  digest: string;
  state: "pending" | "enqueued";
}

export class RoomGovernor extends DurableObject<RuntimeEnv> {
  constructor(ctx: DurableObjectState, env: RuntimeEnv) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS room (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          tenant_id TEXT NOT NULL,
          senti_session_id TEXT NOT NULL,
          room_epoch TEXT NOT NULL,
          room_id TEXT NOT NULL,
          provider_meeting_id TEXT,
          lifecycle TEXT NOT NULL,
          provision_fence TEXT,
          provision_lease_until INTEGER,
          control_revision INTEGER NOT NULL DEFAULT 0,
          transcript_mode TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS admissions (
          participant_key TEXT PRIMARY KEY,
          principal_id TEXT,
          membership_role TEXT,
          role TEXT,
          pending_role TEXT,
          provider_participant_id TEXT,
          state TEXT NOT NULL,
          fence TEXT,
          lease_until INTEGER,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS webhook_deliveries (
          delivery_id TEXT PRIMARY KEY,
          digest TEXT NOT NULL,
          event_name TEXT NOT NULL,
          state TEXT NOT NULL,
          received_at TEXT NOT NULL,
          enqueued_at TEXT
        );
        CREATE TABLE IF NOT EXISTS participants (
          participant_key TEXT PRIMARY KEY,
          joined_at TEXT,
          accumulated_ms INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS daily_usage (
          usage_day TEXT PRIMARY KEY,
          control_requests INTEGER NOT NULL DEFAULT 0,
          participant_ms INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL
        );
      `);
      ensureColumn(this.ctx.storage.sql, "room_control_revision");
      ensureColumn(this.ctx.storage.sql, "admission_principal_id");
      ensureColumn(this.ctx.storage.sql, "admission_membership_role");
      this.ctx.storage.sql.exec(`
        CREATE UNIQUE INDEX IF NOT EXISTS admissions_principal_id
          ON admissions(principal_id)
          WHERE principal_id IS NOT NULL;
        CREATE TABLE IF NOT EXISTS moderation_commands (
          command_id TEXT PRIMARY KEY,
          idempotency_hash TEXT NOT NULL UNIQUE,
          payload_hash TEXT NOT NULL,
          actor_principal_id TEXT NOT NULL,
          target_principal_id TEXT NOT NULL,
          target_participant_key TEXT NOT NULL,
          provider_participant_id TEXT NOT NULL,
          action TEXT NOT NULL,
          expected_revision INTEGER NOT NULL,
          result_revision INTEGER NOT NULL,
          state TEXT NOT NULL,
          execution_fence TEXT,
          execution_lease_until INTEGER,
          result_code TEXT,
          provider_mutation_applied INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          finalized_at TEXT,
          CHECK (state IN ('pending', 'unsupported')),
          CHECK (provider_mutation_applied = 0)
        );
        CREATE INDEX IF NOT EXISTS moderation_commands_finalized_at
          ON moderation_commands(finalized_at);
      `);
    });
  }

  reserveProvision(
    tenantId: string,
    sessionId: string,
    roomEpoch: string,
    roomId: string,
    transcriptMode: "post-meeting",
    now: string,
    maxDailyRequests: number,
  ): ProvisionReservation {
    return this.ctx.storage.transactionSync(() => {
      if (!this.consumeControlRequest(now, maxDailyRequests)) {
        return { disposition: "over_budget" };
      }
      const existing = this.roomRow();
      if (
        existing &&
        !matchesRoomIdentity(existing, tenantId, sessionId, roomEpoch, roomId)
      ) {
        return { disposition: "identity_mismatch" };
      }
      if (existing?.lifecycle === "ready") {
        return { disposition: "ready", room: toRoomRecord(existing) };
      }
      if (existing?.lifecycle === "ended") return { disposition: "ended" };
      const nowMs = Date.parse(now);
      if (
        existing?.lifecycle === "provisioning" &&
        existing.provision_lease_until !== null &&
        existing.provision_lease_until > nowMs
      ) {
        return { disposition: "busy" };
      }
      const fence = crypto.randomUUID();
      if (existing) {
        this.ctx.storage.sql.exec(
          `UPDATE room
           SET provision_fence = ?, provision_lease_until = ?, updated_at = ?
           WHERE singleton = 1`,
          fence,
          nowMs + PROVISION_LEASE_MS,
          now,
        );
      } else {
        this.ctx.storage.sql.exec(
          `INSERT INTO room (
             singleton, tenant_id, senti_session_id, room_epoch, room_id, lifecycle,
             provision_fence, provision_lease_until, transcript_mode, created_at, updated_at
           ) VALUES (1, ?, ?, ?, ?, 'provisioning', ?, ?, ?, ?, ?)`,
          tenantId,
          sessionId,
          roomEpoch,
          roomId,
          fence,
          nowMs + PROVISION_LEASE_MS,
          transcriptMode,
          now,
          now,
        );
      }
      return { disposition: "acquired", fence };
    });
  }

  completeProvision(fence: string, providerMeetingId: string, now: string): RoomRecord | null {
    return this.ctx.storage.transactionSync(() => {
      const room = this.roomRow();
      if (
        !room ||
        room.lifecycle !== "provisioning" ||
        room.provision_fence !== fence
      ) {
        return null;
      }
      this.ctx.storage.sql.exec(
        `UPDATE room
         SET provider_meeting_id = ?, lifecycle = 'ready',
             provision_fence = NULL, provision_lease_until = NULL, updated_at = ?
         WHERE singleton = 1`,
        providerMeetingId,
        now,
      );
      return toRoomRecord(this.roomRowRequired());
    });
  }

  releaseProvision(fence: string, now: string): void {
    this.ctx.storage.transactionSync(() => {
      const room = this.roomRow();
      if (room?.lifecycle === "provisioning" && room.provision_fence === fence) {
        this.ctx.storage.sql.exec(
          `UPDATE room
           SET provision_lease_until = 0, provision_fence = NULL, updated_at = ?
           WHERE singleton = 1`,
          now,
        );
      }
    });
  }

  getRoom(
    tenantId: string,
    sessionId: string,
    roomEpoch: string,
    roomId: string,
  ): RoomRecord | null {
    const room = this.roomRow();
    return room?.lifecycle === "ready" &&
      matchesRoomIdentity(room, tenantId, sessionId, roomEpoch, roomId)
      ? toRoomRecord(room)
      : null;
  }

  reserveAdmission(
    participantKey: string,
    principalId: string,
    membershipRole: SentiMembershipRole,
    desiredRole: VoiceRole,
    now: string,
    maxDailyRequests: number,
  ): AdmissionReservation {
    return this.ctx.storage.transactionSync(() => {
      if (!this.consumeControlRequest(now, maxDailyRequests)) {
        return { disposition: "over_budget" };
      }
      const room = this.roomRow();
      if (!room || room.lifecycle !== "ready" || !room.provider_meeting_id) {
        return { disposition: "room_not_ready" };
      }
      const admission = this.admissionRow(participantKey);
      if (
        admission &&
        admission.principal_id !== null &&
        admission.principal_id !== principalId
      ) {
        return { disposition: "identity_mismatch" };
      }
      const nowMs = Date.parse(now);
      if (
        admission?.state === "provisioning" &&
        admission.lease_until !== null &&
        admission.lease_until > nowMs
      ) {
        return { disposition: "busy" };
      }
      const fence = crypto.randomUUID();
      const disposition =
        admission?.provider_participant_id === null || admission === null
          ? "create"
          : admission.role === desiredRole
            ? "refresh"
            : "update";
      if (admission) {
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET principal_id = COALESCE(principal_id, ?), membership_role = ?,
               pending_role = ?, state = 'provisioning', fence = ?,
               lease_until = ?, updated_at = ?
           WHERE participant_key = ?`,
          principalId,
          membershipRole,
          desiredRole,
          fence,
          nowMs + ADMISSION_LEASE_MS,
          now,
          participantKey,
        );
      } else {
        this.ctx.storage.sql.exec(
          `INSERT INTO admissions (
             participant_key, principal_id, membership_role, role, pending_role,
             provider_participant_id, state, fence, lease_until, updated_at
           ) VALUES (?, ?, ?, NULL, ?, NULL, 'provisioning', ?, ?, ?)`,
          participantKey,
          principalId,
          membershipRole,
          desiredRole,
          fence,
          nowMs + ADMISSION_LEASE_MS,
          now,
        );
      }
      return {
        disposition,
        fence,
        providerParticipantId: admission?.provider_participant_id ?? null,
      } as AdmissionReservation;
    });
  }

  completeAdmission(
    participantKey: string,
    fence: string,
    providerParticipantId: string,
    now: string,
  ): boolean {
    return this.ctx.storage.transactionSync(() => {
      const admission = this.admissionRow(participantKey);
      if (
        !admission ||
        admission.state !== "provisioning" ||
        admission.fence !== fence ||
        !admission.pending_role
      ) {
        return false;
      }
      this.ctx.storage.sql.exec(
        `UPDATE admissions
         SET role = pending_role, pending_role = NULL, provider_participant_id = ?,
             state = 'active', fence = NULL, lease_until = NULL, updated_at = ?
         WHERE participant_key = ?`,
        providerParticipantId,
        now,
        participantKey,
      );
      return true;
    });
  }

  releaseAdmission(participantKey: string, fence: string, now: string): void {
    this.ctx.storage.transactionSync(() => {
      const admission = this.admissionRow(participantKey);
      if (admission?.state !== "provisioning" || admission.fence !== fence) return;
      if (admission.provider_participant_id) {
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET pending_role = NULL, state = 'active', fence = NULL, lease_until = NULL,
               updated_at = ? WHERE participant_key = ?`,
          now,
          participantKey,
        );
      } else {
        this.ctx.storage.sql.exec(
          "DELETE FROM admissions WHERE participant_key = ?",
          participantKey,
        );
      }
    });
  }

  reserveModeration(
    input: ModerationReservationInput,
  ): ModerationReservation {
    return this.ctx.storage.transactionSync(() => {
      const room = this.roomRow();
      const currentRevision = room?.control_revision ?? 0;
      if (
        !room ||
        room.lifecycle !== "ready" ||
        !room.provider_meeting_id
      ) {
        return { disposition: "room_not_ready", currentRevision };
      }
      if (
        !matchesRoomIdentity(
          room,
          input.tenantId,
          input.sessionId,
          input.roomEpoch,
          input.roomId,
        )
      ) {
        return { disposition: "identity_mismatch", currentRevision };
      }

      const existing = this.commandRows(
        input.commandId,
        input.idempotencyHash,
      );
      if (existing.length > 0) {
        const command = existing[0];
        if (
          existing.length !== 1 ||
          !command ||
          command.command_id !== input.commandId ||
          command.idempotency_hash !== input.idempotencyHash ||
          command.payload_hash !== input.payloadHash ||
          command.actor_principal_id !== input.actorPrincipalId
        ) {
          return { disposition: "idempotency_conflict", currentRevision };
        }
        if (command.state === "unsupported") {
          return {
            disposition: "replay",
            command: toModerationCommandRecord(command),
          };
        }
        const actor = this.admissionByPrincipal(input.actorPrincipalId);
        const target = this.admissionByPrincipal(
          command.target_principal_id,
        );
        if (
          (input.actorMembershipRole !== "owner" &&
            input.actorMembershipRole !== "admin") ||
          !actor ||
          actor.state !== "active" ||
          actor.role !== "moderator" ||
          !actor.provider_participant_id
        ) {
          return { disposition: "not_authorized", currentRevision };
        }
        if (
          !target ||
          target.state !== "active" ||
          target.participant_key !== command.target_participant_key ||
          target.provider_participant_id !==
            command.provider_participant_id
        ) {
          return { disposition: "target_not_found", currentRevision };
        }
        const nowMs = Date.parse(input.now);
        if (
          command.execution_lease_until !== null &&
          command.execution_lease_until > nowMs
        ) {
          return {
            disposition: "busy",
            command: toModerationCommandRecord(command),
          };
        }
        const fence = crypto.randomUUID();
        this.ctx.storage.sql.exec(
          `UPDATE moderation_commands
           SET execution_fence = ?, execution_lease_until = ?
           WHERE command_id = ? AND state = 'pending'`,
          fence,
          nowMs + COMMAND_LEASE_MS,
          command.command_id,
        );
        const reacquired = this.moderationCommandRow(command.command_id);
        return {
          disposition: "execute",
          fence,
          room: toRoomRecord(room),
          command: toModerationCommandRecord(reacquired),
          targetProviderParticipantId: reacquired.provider_participant_id,
        };
      }

      if (input.expectedRevision !== currentRevision) {
        return { disposition: "revision_conflict", currentRevision };
      }
      if (
        input.actorMembershipRole !== "owner" &&
        input.actorMembershipRole !== "admin"
      ) {
        return { disposition: "not_authorized", currentRevision };
      }
      const actor = this.admissionByPrincipal(input.actorPrincipalId);
      if (
        !actor ||
        actor.state !== "active" ||
        actor.role !== "moderator" ||
        !actor.provider_participant_id
      ) {
        return { disposition: "not_authorized", currentRevision };
      }
      const target = this.admissionByPrincipal(input.targetPrincipalId);
      if (
        !target ||
        target.state !== "active" ||
        !target.provider_participant_id
      ) {
        return { disposition: "target_not_found", currentRevision };
      }
      this.pruneCommands(input.now);
      if (this.commandCount() >= MAX_COMMANDS) {
        return { disposition: "command_capacity", currentRevision };
      }
      if (!this.consumeControlRequest(input.now, input.maxDailyRequests)) {
        return { disposition: "over_budget", currentRevision };
      }

      const resultRevision = currentRevision + 1;
      const fence = crypto.randomUUID();
      const leaseUntil = Date.parse(input.now) + COMMAND_LEASE_MS;
      this.ctx.storage.sql.exec(
        `INSERT INTO moderation_commands (
           command_id, idempotency_hash, payload_hash, actor_principal_id,
           target_principal_id, target_participant_key,
           provider_participant_id, action, expected_revision,
           result_revision, state, execution_fence, execution_lease_until,
           result_code, provider_mutation_applied, created_at, finalized_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, NULL, 0, ?, NULL)`,
        input.commandId,
        input.idempotencyHash,
        input.payloadHash,
        input.actorPrincipalId,
        input.targetPrincipalId,
        target.participant_key,
        target.provider_participant_id,
        input.action,
        input.expectedRevision,
        resultRevision,
        fence,
        leaseUntil,
        input.now,
      );
      this.ctx.storage.sql.exec(
        `UPDATE room
         SET control_revision = ?, updated_at = ?
         WHERE singleton = 1 AND control_revision = ?`,
        resultRevision,
        input.now,
        currentRevision,
      );
      const command = this.moderationCommandRow(input.commandId);
      return {
        disposition: "execute",
        fence,
        room: toRoomRecord(this.roomRowRequired()),
        command: toModerationCommandRecord(command),
        targetProviderParticipantId: command.provider_participant_id,
      };
    });
  }

  finalizeModerationUnsupported(
    commandId: string,
    fence: string,
    now: string,
  ): ModerationCommandRecord | null {
    return this.ctx.storage.transactionSync(() => {
      const command = this.moderationCommandRowOrNull(commandId);
      if (
        !command ||
        command.state !== "pending" ||
        command.execution_fence !== fence
      ) {
        return null;
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET state = 'unsupported', execution_fence = NULL,
             execution_lease_until = NULL, result_code = 'executor_unavailable',
             provider_mutation_applied = 0, finalized_at = ?
         WHERE command_id = ? AND state = 'pending' AND execution_fence = ?`,
        now,
        commandId,
        fence,
      );
      return toModerationCommandRecord(
        this.moderationCommandRow(commandId),
      );
    });
  }

  acceptWebhook(
    event: WebhookEventSummary,
    now: string,
    maxDailyRequests: number,
  ): WebhookAcceptance {
    return this.ctx.storage.transactionSync(() => {
      if (!this.consumeControlRequest(now, maxDailyRequests)) {
        return { disposition: "over_budget" };
      }
      const room = this.roomRow();
      if (!room?.provider_meeting_id) return { disposition: "unknown_room" };
      if (room.provider_meeting_id !== event.providerMeetingId) {
        return { disposition: "meeting_mismatch" };
      }
      const delivery = this.deliveryRow(event.deliveryId);
      if (delivery?.digest !== undefined && delivery.digest !== event.digest) {
        return { disposition: "digest_conflict" };
      }
      const roomRecord = toRoomRecord(room);
      if (delivery?.state === "enqueued") {
        return { disposition: "duplicate", room: roomRecord };
      }
      if (delivery?.state === "pending") {
        return { disposition: "retry", room: roomRecord };
      }

      this.ctx.storage.sql.exec(
        `INSERT INTO webhook_deliveries (
           delivery_id, digest, event_name, state, received_at, enqueued_at
         ) VALUES (?, ?, ?, 'pending', ?, NULL)`,
        event.deliveryId,
        event.digest,
        event.eventName,
        now,
      );
      this.applyEvent(event, now);
      this.pruneDeliveries(now);
      return { disposition: "new", room: toRoomRecord(this.roomRowRequired()) };
    });
  }

  markWebhookEnqueued(deliveryId: string, digest: string, now: string): boolean {
    return this.ctx.storage.transactionSync(() => {
      const delivery = this.deliveryRow(deliveryId);
      if (!delivery || delivery.digest !== digest) return false;
      this.ctx.storage.sql.exec(
        `UPDATE webhook_deliveries
         SET state = 'enqueued', enqueued_at = ?
         WHERE delivery_id = ? AND digest = ?`,
        now,
        deliveryId,
        digest,
      );
      return true;
    });
  }

  usageSnapshot(
    now: string,
    maxDailyRequests: number,
    neuronsPerAudioMinute: number,
  ): UsageResult {
    return this.ctx.storage.transactionSync(() => {
      if (!this.consumeControlRequest(now, maxDailyRequests)) {
        return { disposition: "over_budget" };
      }
      const room = this.roomRow();
      if (!room?.provider_meeting_id) return { disposition: "room_not_ready" };
      const usageDay = now.slice(0, 10);
      const usage = this.ctx.storage.sql
        .exec<{ control_requests: number; participant_ms: number }>(
          `SELECT control_requests, participant_ms
           FROM daily_usage WHERE usage_day = ?`,
          usageDay,
        )
        .one();
      const participantMinutes = usage.participant_ms / 60_000;
      return {
        disposition: "ok",
        room: toRoomRecord(room),
        usage: {
          usageDay,
          controlRequests: usage.control_requests,
          completedParticipantMs: usage.participant_ms,
          completedParticipantMinutes: participantMinutes,
          transcriptionNeuronsEstimate: participantMinutes * neuronsPerAudioMinute,
          estimateBasis: "completed-participant-presence",
          billingTruth: false,
        },
      };
    });
  }

  debugSnapshot(): {
    room: RoomRecord | null;
    controlRequests: number;
    deliveryCount: number;
    participantCount: number;
    commandCount: number;
    pendingCommandCount: number;
    transcriptBodyColumns: 0;
  } {
    const room = this.roomRow();
    const delivery = this.ctx.storage.sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM webhook_deliveries")
      .one();
    const participants = this.ctx.storage.sql
      .exec<{ count: number }>("SELECT COUNT(*) AS count FROM participants")
      .one();
    const usage = this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COALESCE(SUM(control_requests), 0) AS count FROM daily_usage",
      )
      .one();
    const commands = this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM moderation_commands",
      )
      .one();
    const pendingCommands = this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM moderation_commands WHERE state = 'pending'",
      )
      .one();
    return {
      room: room ? toRoomRecord(room) : null,
      controlRequests: usage.count,
      deliveryCount: delivery.count,
      participantCount: participants.count,
      commandCount: commands.count,
      pendingCommandCount: pendingCommands.count,
      transcriptBodyColumns: 0,
    };
  }

  private applyEvent(event: WebhookEventSummary, now: string): void {
    if (event.eventName === "meeting.ended") {
      this.ctx.storage.sql.exec(
        "UPDATE room SET lifecycle = 'ended', updated_at = ? WHERE singleton = 1",
        now,
      );
      return;
    }
    if (!event.customParticipantId) return;
    if (event.eventName === "meeting.participantJoined" && event.participantJoinedAt) {
      this.ctx.storage.sql.exec(
        `INSERT INTO participants (participant_key, joined_at, accumulated_ms, updated_at)
         VALUES (?, ?, 0, ?)
         ON CONFLICT(participant_key) DO UPDATE SET
           joined_at = excluded.joined_at,
           updated_at = excluded.updated_at`,
        event.customParticipantId,
        event.participantJoinedAt,
        now,
      );
    }
    if (event.eventName === "meeting.participantLeft" && event.participantLeftAt) {
      const row = this.ctx.storage.sql
        .exec<{ joined_at: string | null }>(
          "SELECT joined_at FROM participants WHERE participant_key = ?",
          event.customParticipantId,
        )
        .toArray()[0];
      const joinedMs = row?.joined_at ? Date.parse(row.joined_at) : Number.NaN;
      const leftMs = Date.parse(event.participantLeftAt);
      const durationMs =
        Number.isFinite(joinedMs) && Number.isFinite(leftMs)
          ? Math.max(0, Math.min(24 * 60 * 60 * 1_000, leftMs - joinedMs))
          : 0;
      this.ctx.storage.sql.exec(
        `INSERT INTO participants (participant_key, joined_at, accumulated_ms, updated_at)
         VALUES (?, NULL, ?, ?)
         ON CONFLICT(participant_key) DO UPDATE SET
           joined_at = NULL,
           accumulated_ms = accumulated_ms + excluded.accumulated_ms,
           updated_at = excluded.updated_at`,
        event.customParticipantId,
        durationMs,
        now,
      );
      this.addParticipantUsage(event.participantLeftAt, durationMs, now);
    }
  }

  private consumeControlRequest(now: string, maximum: number): boolean {
    const day = now.slice(0, 10);
    const existing = this.ctx.storage.sql
      .exec<{ control_requests: number }>(
        "SELECT control_requests FROM daily_usage WHERE usage_day = ?",
        day,
      )
      .toArray()[0];
    if (existing && existing.control_requests >= maximum) return false;
    if (existing) {
      this.ctx.storage.sql.exec(
        `UPDATE daily_usage
         SET control_requests = control_requests + 1, updated_at = ?
         WHERE usage_day = ?`,
        now,
        day,
      );
    } else {
      this.ctx.storage.sql.exec(
        `INSERT INTO daily_usage (
           usage_day, control_requests, participant_ms, updated_at
         ) VALUES (?, 1, 0, ?)`,
        day,
        now,
      );
    }
    return true;
  }

  private addParticipantUsage(occurredAt: string, durationMs: number, now: string): void {
    const day = occurredAt.slice(0, 10);
    this.ctx.storage.sql.exec(
      `INSERT INTO daily_usage (usage_day, control_requests, participant_ms, updated_at)
       VALUES (?, 0, ?, ?)
       ON CONFLICT(usage_day) DO UPDATE SET
         participant_ms = participant_ms + excluded.participant_ms,
         updated_at = excluded.updated_at`,
      day,
      durationMs,
      now,
    );
  }

  private pruneDeliveries(now: string): void {
    const cutoff = new Date(Date.parse(now) - DELIVERY_RETENTION_MS).toISOString();
    this.ctx.storage.sql.exec(
      "DELETE FROM webhook_deliveries WHERE state = 'enqueued' AND received_at < ?",
      cutoff,
    );
    this.ctx.storage.sql.exec(
      `DELETE FROM webhook_deliveries
       WHERE delivery_id IN (
         SELECT delivery_id FROM webhook_deliveries
         WHERE state = 'enqueued'
         ORDER BY received_at DESC
         LIMIT -1 OFFSET ?
       )`,
      MAX_DELIVERIES,
    );
  }

  private pruneCommands(now: string): void {
    const cutoff = new Date(
      Date.parse(now) - COMMAND_RETENTION_MS,
    ).toISOString();
    this.ctx.storage.sql.exec(
      `DELETE FROM moderation_commands
       WHERE state = 'unsupported' AND finalized_at < ?`,
      cutoff,
    );
  }

  private roomRow(): RoomRow | null {
    return (
      this.ctx.storage.sql
        .exec<RoomRow>("SELECT * FROM room WHERE singleton = 1")
        .toArray()[0] ?? null
    );
  }

  private roomRowRequired(): RoomRow {
    return this.ctx.storage.sql.exec<RoomRow>("SELECT * FROM room WHERE singleton = 1").one();
  }

  private admissionRow(participantKey: string): AdmissionRow | null {
    return (
      this.ctx.storage.sql
        .exec<AdmissionRow>(
          "SELECT * FROM admissions WHERE participant_key = ?",
          participantKey,
        )
        .toArray()[0] ?? null
    );
  }

  private admissionByPrincipal(principalId: string): AdmissionRow | null {
    return (
      this.ctx.storage.sql
        .exec<AdmissionRow>(
          "SELECT * FROM admissions WHERE principal_id = ?",
          principalId,
        )
        .toArray()[0] ?? null
    );
  }

  private commandRows(
    commandId: string,
    idempotencyHash: string,
  ): ModerationCommandRow[] {
    return this.ctx.storage.sql
      .exec<ModerationCommandRow>(
        `SELECT * FROM moderation_commands
         WHERE command_id = ? OR idempotency_hash = ?`,
        commandId,
        idempotencyHash,
      )
      .toArray();
  }

  private moderationCommandRow(commandId: string): ModerationCommandRow {
    return this.ctx.storage.sql
      .exec<ModerationCommandRow>(
        "SELECT * FROM moderation_commands WHERE command_id = ?",
        commandId,
      )
      .one();
  }

  private moderationCommandRowOrNull(
    commandId: string,
  ): ModerationCommandRow | null {
    return (
      this.ctx.storage.sql
        .exec<ModerationCommandRow>(
          "SELECT * FROM moderation_commands WHERE command_id = ?",
          commandId,
        )
        .toArray()[0] ?? null
    );
  }

  private commandCount(): number {
    return this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM moderation_commands",
      )
      .one().count;
  }

  private deliveryRow(deliveryId: string): DeliveryRow | null {
    return (
      this.ctx.storage.sql
        .exec<DeliveryRow>(
          "SELECT digest, state FROM webhook_deliveries WHERE delivery_id = ?",
          deliveryId,
        )
        .toArray()[0] ?? null
    );
  }
}

function matchesRoomIdentity(
  row: RoomRow,
  tenantId: string,
  sessionId: string,
  roomEpoch: string,
  roomId: string,
): boolean {
  return (
    row.tenant_id === tenantId &&
    row.senti_session_id === sessionId &&
    row.room_epoch === roomEpoch &&
    row.room_id === roomId
  );
}

function toRoomRecord(row: RoomRow): RoomRecord {
  if (!row.provider_meeting_id) {
    throw new Error("Room is missing its provider meeting.");
  }
  return {
    tenantId: row.tenant_id,
    sessionId: row.senti_session_id,
    roomEpoch: row.room_epoch,
    roomId: row.room_id,
    providerMeetingId: row.provider_meeting_id,
    lifecycle: row.lifecycle,
    controlRevision: row.control_revision,
    transcriptMode: row.transcript_mode,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function toModerationCommandRecord(
  row: ModerationCommandRow,
): ModerationCommandRecord {
  return {
    commandId: row.command_id,
    action: row.action,
    targetPrincipalId: row.target_principal_id,
    controlRevision: row.result_revision,
    status: row.state,
    providerMutationApplied: false,
    resultCode: row.result_code,
    createdAt: row.created_at,
    finalizedAt: row.finalized_at,
  };
}

const COLUMN_MIGRATIONS = {
  room_control_revision: {
    table: "room",
    column: "control_revision",
    statement:
      "ALTER TABLE room ADD COLUMN control_revision INTEGER NOT NULL DEFAULT 0",
  },
  admission_principal_id: {
    table: "admissions",
    column: "principal_id",
    statement: "ALTER TABLE admissions ADD COLUMN principal_id TEXT",
  },
  admission_membership_role: {
    table: "admissions",
    column: "membership_role",
    statement: "ALTER TABLE admissions ADD COLUMN membership_role TEXT",
  },
} as const;

function ensureColumn(
  sql: SqlStorage,
  migrationId: keyof typeof COLUMN_MIGRATIONS,
): void {
  const migration = COLUMN_MIGRATIONS[migrationId];
  const columns = sql
    .exec<{ name: string }>(`PRAGMA table_info(${migration.table})`)
    .toArray();
  if (columns.some((candidate) => candidate.name === migration.column)) return;
  sql.exec(migration.statement);
}

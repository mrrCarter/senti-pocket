import { DurableObject } from "cloudflare:workers";
import {
  VOICE_CONTROL_QUEUE_SCHEMA,
  type ModerationCommandRecord,
  type RoomRecord,
  type RoomUsageSnapshot,
  type SentiMembershipRole,
  type VoiceControlQueueEnvelope,
  type VoiceModerationAction,
  type VoiceRole,
  type WebhookAcceptance,
  type WebhookEventSummary,
} from "./contracts";
import type { RuntimeEnv } from "./env";

const PROVISION_LEASE_MS = 30_000;
const ADMISSION_LEASE_MS = 15_000;
const COMMAND_LEASE_MS = 15_000;
const COMMAND_RETENTION_MS = 8 * 24 * 60 * 60 * 1_000;
const MAX_COMMANDS = 4_096;
const OUTBOX_INITIAL_DELAY_MS = 250;
const OUTBOX_CONTINUATION_DELAY_MS = 250;
const OUTBOX_BATCH_SIZE = 32;
const OUTBOX_RECOVERY_MS = 30_000;
const COMMAND_TERMINAL_DEADLINE_MS = 10 * 60 * 1_000;
const DELIVERY_RETENTION_MS = 8 * 24 * 60 * 60 * 1_000;
const MAX_DELIVERIES = 2_048;
const MAX_INACTIVE_PEERS_PER_PARTICIPANT = 4;

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
      disposition: "accepted";
      command: ModerationCommandRecord;
    }
  | {
      disposition: "replay";
      command: ModerationCommandRecord;
    }
  | {
      disposition: "revision_conflict";
      currentRevision: number;
    }
  | { disposition: "idempotency_conflict"; currentRevision: number }
  | { disposition: "not_authorized"; currentRevision: number }
  | { disposition: "target_not_found"; currentRevision: number }
  | { disposition: "target_busy"; currentRevision: number }
  | { disposition: "room_not_ready"; currentRevision: number }
  | { disposition: "identity_mismatch"; currentRevision: number }
  | { disposition: "over_budget"; currentRevision: number }
  | { disposition: "command_capacity"; currentRevision: number };

export type ModerationExecutionReservation =
  | {
      disposition: "execute";
      fence: string;
      room: RoomRecord;
      command: ModerationCommandRecord;
      actorPrincipalId: string;
      targetParticipantKey: string;
      targetProviderParticipantId: string;
      targetProviderSessionId: string | null;
      targetPeerId: string | null;
    }
  | {
      disposition: "terminal";
      command: ModerationCommandRecord;
    }
  | {
      disposition: "waiting_observation";
      command: ModerationCommandRecord;
    }
  | { disposition: "busy" }
  | { disposition: "not_authorized" }
  | { disposition: "target_not_found" }
  | { disposition: "invalid" };

export type RemoveAttemptReservation =
  | {
      disposition: "ready";
      attemptId: string;
      startedAt: string;
    }
  | { disposition: "invalid" }
  | { disposition: "authorization_expired" };

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
  target_provider_session_id: string | null;
  target_peer_id: string | null;
  action: VoiceModerationAction;
  expected_revision: number;
  result_revision: number;
  state:
    | "pending"
    | "executing"
    | "pending_observation"
    | "desired_state_observed"
    | "conflict"
    | "unsupported";
  execution_fence: string | null;
  execution_lease_until: number | null;
  execution_attempt_id: string | null;
  attempt_started_at: string | null;
  provider_request_accepted: 0 | 1;
  provider_state_observed: 0 | 1;
  causality_proven: 0;
  result_code:
    | "executor_unavailable"
    | "queue_delivery_exhausted"
    | "REMOVE_LEAVE_OBSERVED"
    | "REMOVE_ALREADY_ABSENT_OBSERVED"
    | "VOICE_CONTROL_CONFLICT"
    | null;
  provider_mutation_applied: 0;
  created_at: string;
  finalized_at: string | null;
}

interface DeliveryRow {
  [key: string]: SqlStorageValue;
  digest: string;
  state: "pending" | "enqueued";
}

interface ModerationOutboxRow {
  [key: string]: SqlStorageValue;
  command_id: string;
  room_id: string;
  result_revision: number;
  state: "pending" | "dispatched";
  dispatch_attempts: number;
  last_attempt_at: string | null;
  dispatched_at: string | null;
}

interface PendingCommandDeadlineRow {
  [key: string]: SqlStorageValue;
  created_at: string;
  attempt_started_at: string | null;
  state: ModerationCommandRow["state"];
  execution_lease_until: number | null;
}

interface ParticipantPeerRow {
  [key: string]: SqlStorageValue;
  provider_session_id: string;
  peer_id: string;
  participant_key: string;
  joined_at: string;
  left_at: string | null;
  active: 0 | 1;
  usage_counted: 0 | 1;
  updated_at: string;
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
        CREATE TABLE IF NOT EXISTS participant_peers (
          provider_session_id TEXT NOT NULL,
          peer_id TEXT NOT NULL,
          participant_key TEXT NOT NULL,
          joined_at TEXT NOT NULL,
          left_at TEXT,
          active INTEGER NOT NULL DEFAULT 1,
          usage_counted INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL,
          PRIMARY KEY (provider_session_id, peer_id),
          CHECK (active IN (0, 1)),
          CHECK (usage_counted IN (0, 1))
        );
        CREATE UNIQUE INDEX IF NOT EXISTS participant_peers_one_active
          ON participant_peers(participant_key)
          WHERE active = 1;
        CREATE INDEX IF NOT EXISTS participant_peers_by_participant
          ON participant_peers(participant_key, active, joined_at);
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
          target_provider_session_id TEXT,
          target_peer_id TEXT,
          action TEXT NOT NULL,
          expected_revision INTEGER NOT NULL,
          result_revision INTEGER NOT NULL,
          state TEXT NOT NULL,
          execution_fence TEXT,
          execution_lease_until INTEGER,
          execution_attempt_id TEXT,
          attempt_started_at TEXT,
          provider_request_accepted INTEGER NOT NULL DEFAULT 0,
          provider_state_observed INTEGER NOT NULL DEFAULT 0,
          causality_proven INTEGER NOT NULL DEFAULT 0,
          result_code TEXT,
          provider_mutation_applied INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          finalized_at TEXT,
          CHECK (state IN (
            'pending', 'executing', 'pending_observation',
            'desired_state_observed', 'conflict', 'unsupported'
          )),
          CHECK (provider_request_accepted IN (0, 1)),
          CHECK (provider_state_observed IN (0, 1)),
          CHECK (causality_proven = 0),
          CHECK (provider_mutation_applied = 0),
          CHECK (
            (state = 'desired_state_observed' AND provider_state_observed = 1)
            OR
            (state != 'desired_state_observed' AND provider_state_observed = 0)
          ),
          CHECK (
            provider_request_accepted = 0 OR action = 'remove'
          ),
          CHECK (
            state NOT IN ('executing', 'pending_observation', 'desired_state_observed')
            OR action = 'remove'
          ),
          CHECK (
            (state IN ('pending', 'executing', 'pending_observation')
              AND result_code IS NULL)
            OR
            (state = 'desired_state_observed'
              AND result_code IN (
                'REMOVE_LEAVE_OBSERVED',
                'REMOVE_ALREADY_ABSENT_OBSERVED'
              ))
            OR
            (state = 'conflict' AND result_code = 'VOICE_CONTROL_CONFLICT')
            OR
            (state = 'unsupported'
              AND result_code IN (
                'executor_unavailable',
                'queue_delivery_exhausted'
              ))
          ),
          CHECK (
            action != 'remove'
            OR target_peer_id IS NULL
            OR target_provider_session_id IS NOT NULL
          )
        );
        CREATE INDEX IF NOT EXISTS moderation_commands_finalized_at
          ON moderation_commands(finalized_at);
        CREATE UNIQUE INDEX IF NOT EXISTS moderation_commands_active_remove_peer
          ON moderation_commands(target_provider_session_id, target_peer_id)
          WHERE action = 'remove'
            AND target_peer_id IS NOT NULL
            AND state IN ('pending', 'executing', 'pending_observation');
        CREATE INDEX IF NOT EXISTS moderation_commands_remove_observation
          ON moderation_commands(
            target_provider_session_id, target_peer_id,
            target_participant_key, state, attempt_started_at
          )
          WHERE action = 'remove';
        CREATE TABLE IF NOT EXISTS moderation_outbox (
          command_id TEXT PRIMARY KEY,
          room_id TEXT NOT NULL,
          result_revision INTEGER NOT NULL,
          state TEXT NOT NULL,
          dispatch_attempts INTEGER NOT NULL DEFAULT 0,
          last_attempt_at TEXT,
          dispatched_at TEXT,
          CHECK (state IN ('pending', 'dispatched')),
          CHECK (dispatch_attempts >= 0)
        );
        CREATE INDEX IF NOT EXISTS moderation_outbox_pending
          ON moderation_outbox(state, result_revision);
        INSERT OR IGNORE INTO moderation_outbox (
          command_id, room_id, result_revision, state, dispatch_attempts,
          last_attempt_at, dispatched_at
        )
        SELECT commands.command_id, room.room_id, commands.result_revision,
               'pending', 0, NULL, NULL
        FROM moderation_commands AS commands
        CROSS JOIN room
        WHERE room.singleton = 1
          AND commands.state IN ('pending', 'executing');
      `);
      if (this.pendingCommandCount() > 0) {
        const alarm = await this.ctx.storage.getAlarm();
        if (alarm === null) {
          await this.scheduleNextModerationAlarm(Date.now());
        }
      }
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

  async reserveModeration(
    input: ModerationReservationInput,
  ): Promise<ModerationReservation> {
    return this.ctx.storage.transaction(async (txn) => {
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
        if (isTerminalModerationState(command.state)) {
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
        await txn.setAlarm(Date.now() + OUTBOX_INITIAL_DELAY_MS);
        return {
          disposition: "replay",
          command: toModerationCommandRecord(command),
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
      const targetPeer =
        input.action === "remove"
          ? this.activePeerByParticipant(target.participant_key)
          : null;
      if (input.action === "remove" && !targetPeer) {
        return { disposition: "target_not_found", currentRevision };
      }
      if (
        targetPeer &&
        this.hasNonterminalRemoveForPeer(
          targetPeer.provider_session_id,
          targetPeer.peer_id,
        )
      ) {
        return { disposition: "target_busy", currentRevision };
      }
      this.pruneCommands(input.now);
      if (this.commandCount() >= MAX_COMMANDS) {
        return { disposition: "command_capacity", currentRevision };
      }
      if (!this.consumeControlRequest(input.now, input.maxDailyRequests)) {
        return { disposition: "over_budget", currentRevision };
      }

      const resultRevision = currentRevision + 1;
      // Alarm and SQL writes share this SQLite-backed DO transaction. Scheduling
      // first means a committed intent can never exist without a durable wake-up.
      await txn.setAlarm(Date.now() + OUTBOX_INITIAL_DELAY_MS);
      this.ctx.storage.sql.exec(
        `INSERT INTO moderation_commands (
           command_id, idempotency_hash, payload_hash, actor_principal_id,
           target_principal_id, target_participant_key,
           provider_participant_id, target_provider_session_id, target_peer_id,
           action, expected_revision,
           result_revision, state, execution_fence, execution_lease_until,
           execution_attempt_id, attempt_started_at,
           provider_request_accepted, provider_state_observed,
           causality_proven, result_code, provider_mutation_applied,
           created_at, finalized_at
         ) VALUES (
           ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
           'pending', NULL, NULL, NULL, NULL, 0, 0, 0, NULL, 0, ?, NULL
         )`,
        input.commandId,
        input.idempotencyHash,
        input.payloadHash,
        input.actorPrincipalId,
        input.targetPrincipalId,
        target.participant_key,
        target.provider_participant_id,
        targetPeer?.provider_session_id ?? null,
        targetPeer?.peer_id ?? null,
        input.action,
        input.expectedRevision,
        resultRevision,
        input.now,
      );
      this.ctx.storage.sql.exec(
        `INSERT INTO moderation_outbox (
           command_id, room_id, result_revision, state, dispatch_attempts,
           last_attempt_at, dispatched_at
         ) VALUES (?, ?, ?, 'pending', 0, NULL, NULL)`,
        input.commandId,
        input.roomId,
        resultRevision,
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
        disposition: "accepted",
        command: toModerationCommandRecord(command),
      };
    });
  }

  reserveModerationExecution(
    envelope: VoiceControlQueueEnvelope,
    now: string,
  ): ModerationExecutionReservation {
    return this.ctx.storage.transactionSync(() => {
      const room = this.roomRow();
      const command = this.moderationCommandRowOrNull(envelope.commandId);
      if (
        !room ||
        room.lifecycle !== "ready" ||
        !room.provider_meeting_id ||
        room.room_id !== envelope.roomId ||
        !command ||
        command.result_revision !== envelope.controlRevision
      ) {
        return { disposition: "invalid" };
      }
      if (isTerminalModerationState(command.state)) {
        return {
          disposition: "terminal",
          command: toModerationCommandRecord(command),
        };
      }
      if (command.state === "pending_observation") {
        return {
          disposition: "waiting_observation",
          command: toModerationCommandRecord(command),
        };
      }

      const actor = this.admissionByPrincipal(command.actor_principal_id);
      if (
        !actor ||
        actor.state !== "active" ||
        (actor.membership_role !== "owner" &&
          actor.membership_role !== "admin") ||
        actor.role !== "moderator" ||
        !actor.provider_participant_id
      ) {
        return { disposition: "not_authorized" };
      }
      const target = this.admissionByPrincipal(command.target_principal_id);
      if (
        !target ||
        target.state !== "active" ||
        target.participant_key !== command.target_participant_key ||
        target.provider_participant_id !== command.provider_participant_id
      ) {
        return { disposition: "target_not_found" };
      }

      const nowMs = Date.parse(now);
      if (
        command.execution_lease_until !== null &&
        command.execution_lease_until > nowMs
      ) {
        return { disposition: "busy" };
      }
      const fence = crypto.randomUUID();
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET execution_fence = ?, execution_lease_until = ?
         WHERE command_id = ? AND state IN ('pending', 'executing')`,
        fence,
        nowMs + COMMAND_LEASE_MS,
        command.command_id,
      );
      const acquired = this.moderationCommandRow(command.command_id);
      return {
        disposition: "execute",
        fence,
        room: toRoomRecord(room),
        command: toModerationCommandRecord(acquired),
        actorPrincipalId: acquired.actor_principal_id,
        targetParticipantKey: acquired.target_participant_key,
        targetProviderParticipantId: acquired.provider_participant_id,
        targetProviderSessionId: acquired.target_provider_session_id,
        targetPeerId: acquired.target_peer_id,
      };
    });
  }

  beginRemoveAttempt(
    commandId: string,
    fence: string,
    authorizationValidUntil: string,
    now: string,
  ): RemoveAttemptReservation {
    return this.ctx.storage.transactionSync(() => {
      const command = this.moderationCommandRowOrNull(commandId);
      const nowMs = Date.parse(now);
      const authorizationExpiryMs = Date.parse(authorizationValidUntil);
      if (
        !command ||
        command.action !== "remove" ||
        (command.state !== "pending" && command.state !== "executing") ||
        command.execution_fence !== fence ||
        !command.target_provider_session_id ||
        !command.target_peer_id
      ) {
        return { disposition: "invalid" };
      }
      if (
        !Number.isFinite(nowMs) ||
        !Number.isFinite(authorizationExpiryMs) ||
        authorizationExpiryMs <= nowMs
      ) {
        return { disposition: "authorization_expired" };
      }
      const attemptId = command.execution_attempt_id ?? crypto.randomUUID();
      const startedAt = command.attempt_started_at ?? now;
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET state = 'executing', execution_attempt_id = ?,
             attempt_started_at = ?
         WHERE command_id = ? AND execution_fence = ?
           AND state IN ('pending', 'executing')`,
        attemptId,
        startedAt,
        commandId,
        fence,
      );
      return { disposition: "ready", attemptId, startedAt };
    });
  }

  markRemovePendingObservation(
    commandId: string,
    fence: string,
    attemptId: string,
    now: string,
  ): ModerationCommandRecord | null {
    return this.ctx.storage.transactionSync(() => {
      const command = this.moderationCommandRowOrNull(commandId);
      if (
        command?.action === "remove" &&
        command.execution_attempt_id === attemptId &&
        isTerminalModerationState(command.state)
      ) {
        return toModerationCommandRecord(command);
      }
      if (
        !command ||
        command.action !== "remove" ||
        command.state !== "executing" ||
        command.execution_fence !== fence ||
        command.execution_attempt_id !== attemptId
      ) {
        return null;
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET state = 'pending_observation',
             provider_request_accepted = 1,
             execution_fence = NULL, execution_lease_until = NULL
         WHERE command_id = ? AND state = 'executing'
           AND execution_fence = ? AND execution_attempt_id = ?`,
        commandId,
        fence,
        attemptId,
      );
      this.ctx.storage.sql.exec(
        `UPDATE moderation_outbox
         SET state = 'dispatched', dispatched_at = COALESCE(dispatched_at, ?)
         WHERE command_id = ?`,
        now,
        commandId,
      );
      return toModerationCommandRecord(
        this.moderationCommandRow(commandId),
      );
    });
  }

  finalizeRemoveDesiredStateObserved(
    commandId: string,
    fence: string,
    attemptId: string,
    resultCode:
      | "REMOVE_LEAVE_OBSERVED"
      | "REMOVE_ALREADY_ABSENT_OBSERVED",
    providerRequestAccepted: boolean,
    now: string,
  ): ModerationCommandRecord | null {
    return this.ctx.storage.transactionSync(() => {
      const command = this.moderationCommandRowOrNull(commandId);
      if (
        command?.action === "remove" &&
        command.execution_attempt_id === attemptId &&
        isTerminalModerationState(command.state)
      ) {
        return toModerationCommandRecord(command);
      }
      if (
        !command ||
        command.action !== "remove" ||
        command.state !== "executing" ||
        command.execution_fence !== fence ||
        command.execution_attempt_id !== attemptId
      ) {
        return null;
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET state = 'desired_state_observed',
             provider_request_accepted = ?, provider_state_observed = 1,
             causality_proven = 0, result_code = ?,
             execution_fence = NULL, execution_lease_until = NULL,
             finalized_at = ?
         WHERE command_id = ? AND state = 'executing'
           AND execution_fence = ? AND execution_attempt_id = ?`,
        providerRequestAccepted ? 1 : 0,
        resultCode,
        now,
        commandId,
        fence,
        attemptId,
      );
      this.markOutboxTerminal(commandId, now);
      return toModerationCommandRecord(
        this.moderationCommandRow(commandId),
      );
    });
  }

  finalizeRemoveConflict(
    commandId: string,
    fence: string,
    attemptId: string | null,
    now: string,
  ): ModerationCommandRecord | null {
    return this.ctx.storage.transactionSync(() => {
      const command = this.moderationCommandRowOrNull(commandId);
      if (
        command?.action === "remove" &&
        (attemptId === null ||
          command.execution_attempt_id === attemptId) &&
        isTerminalModerationState(command.state)
      ) {
        return toModerationCommandRecord(command);
      }
      if (
        !command ||
        command.action !== "remove" ||
        (command.state !== "pending" && command.state !== "executing") ||
        command.execution_fence !== fence ||
        (attemptId !== null && command.execution_attempt_id !== attemptId)
      ) {
        return null;
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET state = 'conflict', provider_state_observed = 0,
             causality_proven = 0, result_code = 'VOICE_CONTROL_CONFLICT',
             execution_fence = NULL, execution_lease_until = NULL,
             finalized_at = ?
         WHERE command_id = ? AND execution_fence = ?
           AND state IN ('pending', 'executing')`,
        now,
        commandId,
        fence,
      );
      this.markOutboxTerminal(commandId, now);
      return toModerationCommandRecord(
        this.moderationCommandRow(commandId),
      );
    });
  }

  releaseModerationExecution(
    commandId: string,
    fence: string,
  ): boolean {
    return this.ctx.storage.transactionSync(() => {
      const command = this.moderationCommandRowOrNull(commandId);
      if (
        !command ||
        isTerminalModerationState(command.state) ||
        command.execution_fence !== fence
      ) {
        return false;
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_commands
         SET execution_fence = NULL, execution_lease_until = NULL
         WHERE command_id = ? AND execution_fence = ?`,
        commandId,
        fence,
      );
      return true;
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
      this.ctx.storage.sql.exec(
        `UPDATE moderation_outbox
         SET state = 'dispatched', dispatched_at = COALESCE(dispatched_at, ?)
         WHERE command_id = ?`,
        now,
        commandId,
      );
      return toModerationCommandRecord(
        this.moderationCommandRow(commandId),
      );
    });
  }

  finalizeModerationUndelivered(
    envelope: VoiceControlQueueEnvelope,
    now: string,
  ): ModerationCommandRecord | null {
    return this.ctx.storage.transactionSync(() => {
      const room = this.roomRow();
      const command = this.moderationCommandRowOrNull(envelope.commandId);
      if (
        !room ||
        room.room_id !== envelope.roomId ||
        !command ||
        command.result_revision !== envelope.controlRevision
      ) {
        return null;
      }
      if (isTerminalModerationState(command.state)) {
        return toModerationCommandRecord(command);
      }
      const nowMs = Date.parse(now);
      if (
        command.execution_lease_until !== null &&
        command.execution_lease_until > nowMs
      ) {
        return null;
      }
      if (command.state === "pending") {
        this.ctx.storage.sql.exec(
          `UPDATE moderation_commands
           SET state = 'unsupported', execution_fence = NULL,
               execution_lease_until = NULL,
               result_code = 'queue_delivery_exhausted',
               provider_mutation_applied = 0, finalized_at = ?
           WHERE command_id = ? AND state = 'pending'
             AND (
               execution_lease_until IS NULL OR execution_lease_until <= ?
             )`,
          now,
          envelope.commandId,
          nowMs,
        );
      } else {
        this.ctx.storage.sql.exec(
          `UPDATE moderation_commands
           SET state = 'conflict', execution_fence = NULL,
               execution_lease_until = NULL,
               provider_state_observed = 0, causality_proven = 0,
               result_code = 'VOICE_CONTROL_CONFLICT', finalized_at = ?
           WHERE command_id = ?
             AND state IN ('executing', 'pending_observation')
             AND (
               execution_lease_until IS NULL OR execution_lease_until <= ?
             )`,
          now,
          envelope.commandId,
          nowMs,
        );
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_outbox
         SET state = 'dispatched', dispatched_at = COALESCE(dispatched_at, ?)
         WHERE command_id = ?`,
        now,
        envelope.commandId,
      );
      return toModerationCommandRecord(
        this.moderationCommandRow(envelope.commandId),
      );
    });
  }

  override async alarm(): Promise<void> {
    // Pre-arm recovery before Queue I/O, then throw on uncertain delivery so
    // both the durable wake-up and Cloudflare's native alarm retry remain live.
    const nowMs = Date.now();
    const now = new Date(nowMs).toISOString();
    await this.ctx.storage.setAlarm(nowMs + OUTBOX_RECOVERY_MS);
    const reconciled = this.reconcileExpiredModerationCommands(now, nowMs);
    if (reconciled > 0) {
      console.warn(
        JSON.stringify({
          event: "voice_control_deadline_commands_terminalized",
          commandCount: reconciled,
        }),
      );
    }
    const pending = this.pendingOutboxRows(OUTBOX_BATCH_SIZE);
    if (pending.length === 0) {
      await this.scheduleNextModerationAlarm(nowMs);
      return;
    }

    const attemptedAt = new Date().toISOString();
    this.recordOutboxAttempt(pending, attemptedAt);
    try {
      await this.env.VOICE_CONTROL_QUEUE.sendBatch(
        pending.map((row) => ({
          body: outboxEnvelope(row),
          contentType: "json",
        })),
      );
      this.markOutboxDispatched(pending, new Date().toISOString());
    } catch {
      console.error(
        JSON.stringify({
          event: "voice_control_outbox_dispatch_deferred",
          commandCount: pending.length,
        }),
      );
      throw new Error("Voice-control outbox dispatch failed.");
    }

    if (this.pendingOutboxCount() > 0) {
      await this.ctx.storage.setAlarm(
        Date.now() + OUTBOX_CONTINUATION_DELAY_MS,
      );
    } else {
      await this.scheduleNextModerationAlarm(Date.now());
    }
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
    pendingOutboxCount: number;
    dispatchedOutboxCount: number;
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
        `SELECT COUNT(*) AS count FROM moderation_commands
         WHERE state IN ('pending', 'executing', 'pending_observation')`,
      )
      .one();
    const pendingOutbox = this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM moderation_outbox WHERE state = 'pending'",
      )
      .one();
    const dispatchedOutbox = this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM moderation_outbox WHERE state = 'dispatched'",
      )
      .one();
    return {
      room: room ? toRoomRecord(room) : null,
      controlRequests: usage.count,
      deliveryCount: delivery.count,
      participantCount: participants.count,
      commandCount: commands.count,
      pendingCommandCount: pendingCommands.count,
      pendingOutboxCount: pendingOutbox.count,
      dispatchedOutboxCount: dispatchedOutbox.count,
      transcriptBodyColumns: 0,
    };
  }

  debugOutboxSnapshot(): Array<{
    commandId: string;
    controlRevision: number;
    state: "pending" | "dispatched";
    dispatchAttempts: number;
  }> {
    return this.ctx.storage.sql
      .exec<ModerationOutboxRow>(
        `SELECT * FROM moderation_outbox
         ORDER BY result_revision, command_id`,
      )
      .toArray()
      .map((row) => ({
        commandId: row.command_id,
        controlRevision: row.result_revision,
        state: row.state,
        dispatchAttempts: row.dispatch_attempts,
      }));
  }

  debugPeerSnapshot(): Array<{
    providerSessionId: string;
    peerId: string;
    participantKey: string;
    joinedAt: string;
    leftAt: string | null;
    active: boolean;
  }> {
    return this.ctx.storage.sql
      .exec<ParticipantPeerRow>(
        `SELECT * FROM participant_peers
         ORDER BY participant_key, joined_at, peer_id`,
      )
      .toArray()
      .map((row) => ({
        providerSessionId: row.provider_session_id,
        peerId: row.peer_id,
        participantKey: row.participant_key,
        joinedAt: row.joined_at,
        leftAt: row.left_at,
        active: row.active === 1,
      }));
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
      this.recordPeerJoined(event, now);
      this.prunePeerHistory(event.customParticipantId);
    }
    if (event.eventName === "meeting.participantLeft" && event.participantLeftAt) {
      this.recordPeerLeft(event, now);
      this.prunePeerHistory(event.customParticipantId);
    }
  }

  private recordPeerJoined(
    event: WebhookEventSummary,
    now: string,
  ): void {
    if (
      !event.customParticipantId ||
      !event.providerSessionId ||
      !event.peerId ||
      !event.participantJoinedAt
    ) {
      return;
    }
    const joinedMs = Date.parse(event.participantJoinedAt);
    if (!Number.isFinite(joinedMs)) return;

    const existing = this.peerRow(event.providerSessionId, event.peerId);
    // A provider-session peer is an immutable connection identity. Duplicate
    // joins cannot rebind it to another participant or resurrect it after it
    // was made historical by a leave or a newer peer generation.
    if (existing) return;

    const active = this.activePeerByParticipant(event.customParticipantId);
    if (active) {
      const activeJoinedMs = Date.parse(active.joined_at);
      const samePeer =
        active.provider_session_id === event.providerSessionId &&
        active.peer_id === event.peerId;
      if (samePeer) return;
      if (
        !Number.isFinite(activeJoinedMs) ||
        joinedMs <= activeJoinedMs
      ) {
        this.upsertInactivePeer(event, now);
        return;
      }
      this.ctx.storage.sql.exec(
        `UPDATE participant_peers
         SET active = 0, updated_at = ?
         WHERE provider_session_id = ? AND peer_id = ? AND active = 1`,
        now,
        active.provider_session_id,
        active.peer_id,
      );
    } else {
      const latest = this.latestPeerByParticipant(
        event.customParticipantId,
      );
      const latestJoinedMs = latest ? Date.parse(latest.joined_at) : NaN;
      if (
        latest &&
        (!Number.isFinite(latestJoinedMs) || joinedMs <= latestJoinedMs)
      ) {
        this.upsertInactivePeer(event, now);
        return;
      }
    }

    this.ctx.storage.sql.exec(
      `INSERT INTO participant_peers (
         provider_session_id, peer_id, participant_key, joined_at,
         left_at, active, usage_counted, updated_at
       ) VALUES (?, ?, ?, ?, NULL, 1, 0, ?)
       ON CONFLICT(provider_session_id, peer_id) DO NOTHING`,
      event.providerSessionId,
      event.peerId,
      event.customParticipantId,
      event.participantJoinedAt,
      now,
    );
    this.ctx.storage.sql.exec(
      `INSERT INTO participants (
         participant_key, joined_at, accumulated_ms, updated_at
       ) VALUES (?, ?, 0, ?)
       ON CONFLICT(participant_key) DO UPDATE SET
         joined_at = excluded.joined_at, updated_at = excluded.updated_at`,
      event.customParticipantId,
      event.participantJoinedAt,
      now,
    );
  }

  private upsertInactivePeer(
    event: WebhookEventSummary,
    now: string,
  ): void {
    this.ctx.storage.sql.exec(
      `INSERT INTO participant_peers (
         provider_session_id, peer_id, participant_key, joined_at,
         left_at, active, usage_counted, updated_at
       ) VALUES (?, ?, ?, ?, NULL, 0, 0, ?)
       ON CONFLICT(provider_session_id, peer_id) DO NOTHING`,
      event.providerSessionId!,
      event.peerId!,
      event.customParticipantId!,
      event.participantJoinedAt!,
      now,
    );
  }

  private recordPeerLeft(
    event: WebhookEventSummary,
    now: string,
  ): void {
    if (
      !event.customParticipantId ||
      !event.providerSessionId ||
      !event.peerId ||
      !event.participantLeftAt
    ) {
      return;
    }
    const peer = this.peerRow(event.providerSessionId, event.peerId);
    if (
      !peer ||
      peer.participant_key !== event.customParticipantId ||
      peer.left_at !== null
    ) {
      return;
    }
    const joinedMs = Date.parse(peer.joined_at);
    const leftMs = Date.parse(event.participantLeftAt);
    if (
      !Number.isFinite(joinedMs) ||
      !Number.isFinite(leftMs) ||
      leftMs < joinedMs
    ) {
      return;
    }
    const durationMs = Math.max(
      0,
      Math.min(24 * 60 * 60 * 1_000, leftMs - joinedMs),
    );
    const countUsage = peer.usage_counted === 0;
    this.ctx.storage.sql.exec(
      `UPDATE participant_peers
       SET left_at = ?, active = 0, usage_counted = 1, updated_at = ?
       WHERE provider_session_id = ? AND peer_id = ?
         AND participant_key = ?`,
      event.participantLeftAt,
      now,
      event.providerSessionId,
      event.peerId,
      event.customParticipantId,
    );
    if (peer.active === 1) {
      this.ctx.storage.sql.exec(
        `UPDATE participants
         SET joined_at = NULL,
             accumulated_ms = accumulated_ms + ?,
             updated_at = ?
         WHERE participant_key = ?`,
        countUsage ? durationMs : 0,
        now,
        event.customParticipantId,
      );
    } else if (countUsage) {
      this.ctx.storage.sql.exec(
        `UPDATE participants
         SET accumulated_ms = accumulated_ms + ?, updated_at = ?
         WHERE participant_key = ?`,
        durationMs,
        now,
        event.customParticipantId,
      );
    }
    if (countUsage) {
      this.addParticipantUsage(
        event.participantLeftAt,
        durationMs,
        now,
      );
    }
    this.observeRemovePeerLeft(event, now);
  }

  private observeRemovePeerLeft(
    event: WebhookEventSummary,
    now: string,
  ): void {
    const command = this.ctx.storage.sql
      .exec<ModerationCommandRow>(
        `SELECT * FROM moderation_commands
         WHERE action = 'remove'
           AND target_provider_session_id = ?
           AND target_peer_id = ?
           AND target_participant_key = ?
           AND state IN ('executing', 'pending_observation')
           AND attempt_started_at IS NOT NULL
           AND attempt_started_at <= ?
         ORDER BY result_revision
         LIMIT 1`,
        event.providerSessionId!,
        event.peerId!,
        event.customParticipantId!,
        event.participantLeftAt!,
      )
      .toArray()[0];
    if (!command) return;
    this.ctx.storage.sql.exec(
      `UPDATE moderation_commands
       SET state = 'desired_state_observed',
           provider_state_observed = 1, causality_proven = 0,
           result_code = 'REMOVE_LEAVE_OBSERVED',
           execution_fence = NULL, execution_lease_until = NULL,
           finalized_at = ?
       WHERE command_id = ?
         AND state IN ('executing', 'pending_observation')
         AND target_provider_session_id = ? AND target_peer_id = ?
         AND attempt_started_at <= ?`,
      now,
      command.command_id,
      event.providerSessionId!,
      event.peerId!,
      event.participantLeftAt!,
    );
    this.markOutboxTerminal(command.command_id, now);
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
      `DELETE FROM moderation_outbox
       WHERE command_id IN (
         SELECT command_id FROM moderation_commands
         WHERE state IN ('unsupported', 'conflict', 'desired_state_observed')
           AND finalized_at < ?
       )`,
      cutoff,
    );
    this.ctx.storage.sql.exec(
      `DELETE FROM moderation_commands
       WHERE state IN ('unsupported', 'conflict', 'desired_state_observed')
         AND finalized_at < ?`,
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

  private activePeerByParticipant(
    participantKey: string,
  ): ParticipantPeerRow | null {
    return (
      this.ctx.storage.sql
        .exec<ParticipantPeerRow>(
          `SELECT * FROM participant_peers
           WHERE participant_key = ? AND active = 1
           ORDER BY joined_at DESC
           LIMIT 1`,
          participantKey,
        )
        .toArray()[0] ?? null
    );
  }

  private latestPeerByParticipant(
    participantKey: string,
  ): ParticipantPeerRow | null {
    return (
      this.ctx.storage.sql
        .exec<ParticipantPeerRow>(
          `SELECT * FROM participant_peers
           WHERE participant_key = ?
           ORDER BY joined_at DESC, provider_session_id DESC, peer_id DESC
           LIMIT 1`,
          participantKey,
        )
        .toArray()[0] ?? null
    );
  }

  private peerRow(
    providerSessionId: string,
    peerId: string,
  ): ParticipantPeerRow | null {
    return (
      this.ctx.storage.sql
        .exec<ParticipantPeerRow>(
          `SELECT * FROM participant_peers
           WHERE provider_session_id = ? AND peer_id = ?`,
          providerSessionId,
          peerId,
        )
        .toArray()[0] ?? null
    );
  }

  private hasNonterminalRemoveForPeer(
    providerSessionId: string,
    peerId: string,
  ): boolean {
    return (
      this.ctx.storage.sql
        .exec<{ count: number }>(
          `SELECT COUNT(*) AS count FROM moderation_commands
           WHERE action = 'remove'
             AND target_provider_session_id = ?
             AND target_peer_id = ?
             AND state IN ('pending', 'executing', 'pending_observation')`,
          providerSessionId,
          peerId,
        )
        .one().count > 0
    );
  }

  private prunePeerHistory(participantKey: string): void {
    this.ctx.storage.sql.exec(
      `DELETE FROM participant_peers
       WHERE rowid IN (
         SELECT peers.rowid
         FROM participant_peers AS peers
         WHERE peers.participant_key = ? AND peers.active = 0
           AND NOT EXISTS (
             SELECT 1
             FROM moderation_commands AS commands
             WHERE commands.action = 'remove'
               AND commands.target_provider_session_id =
                 peers.provider_session_id
               AND commands.target_peer_id = peers.peer_id
               AND commands.state IN (
                 'pending', 'executing', 'pending_observation'
               )
           )
         ORDER BY peers.joined_at DESC,
                  peers.provider_session_id DESC,
                  peers.peer_id DESC
         LIMIT -1 OFFSET ?
       )`,
      participantKey,
      MAX_INACTIVE_PEERS_PER_PARTICIPANT,
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

  private pendingOutboxRows(limit: number): ModerationOutboxRow[] {
    return this.ctx.storage.sql
      .exec<ModerationOutboxRow>(
        `SELECT outbox.*
         FROM moderation_outbox AS outbox
         JOIN moderation_commands AS commands
           ON commands.command_id = outbox.command_id
         WHERE outbox.state = 'pending' AND commands.state = 'pending'
         ORDER BY outbox.result_revision, outbox.command_id
         LIMIT ?`,
        limit,
      )
      .toArray();
  }

  private pendingOutboxCount(): number {
    return this.ctx.storage.sql
      .exec<{ count: number }>(
        `SELECT COUNT(*) AS count
         FROM moderation_outbox AS outbox
         JOIN moderation_commands AS commands
           ON commands.command_id = outbox.command_id
         WHERE outbox.state = 'pending' AND commands.state = 'pending'`,
      )
      .one().count;
  }

  private pendingCommandCount(): number {
    return this.ctx.storage.sql
      .exec<{ count: number }>(
        `SELECT COUNT(*) AS count FROM moderation_commands
         WHERE state IN ('pending', 'executing', 'pending_observation')`,
      )
      .one().count;
  }

  private reconcileExpiredModerationCommands(
    now: string,
    nowMs: number,
  ): number {
    const cutoff = new Date(nowMs - COMMAND_TERMINAL_DEADLINE_MS).toISOString();
    return this.ctx.storage.transactionSync(() => {
      const unattempted = this.ctx.storage.sql
        .exec<{ command_id: string }>(
          `SELECT command_id
           FROM moderation_commands
           WHERE state = 'pending' AND created_at <= ?
             AND (
               execution_lease_until IS NULL OR execution_lease_until <= ?
             )`,
          cutoff,
          nowMs,
        )
        .toArray();
      const attempted = this.ctx.storage.sql
        .exec<{ command_id: string }>(
          `SELECT command_id
           FROM moderation_commands
           WHERE state IN ('executing', 'pending_observation')
             AND attempt_started_at IS NOT NULL
             AND attempt_started_at <= ?
             AND (
               execution_lease_until IS NULL OR execution_lease_until <= ?
             )`,
          cutoff,
          nowMs,
        )
        .toArray();
      if (unattempted.length === 0 && attempted.length === 0) return 0;

      if (unattempted.length > 0) {
        this.ctx.storage.sql.exec(
          `UPDATE moderation_commands
           SET state = 'unsupported', execution_fence = NULL,
               execution_lease_until = NULL,
               result_code = 'queue_delivery_exhausted',
               provider_mutation_applied = 0, finalized_at = ?
           WHERE state = 'pending' AND created_at <= ?
             AND (
               execution_lease_until IS NULL OR execution_lease_until <= ?
             )`,
          now,
          cutoff,
          nowMs,
        );
      }
      if (attempted.length > 0) {
        this.ctx.storage.sql.exec(
          `UPDATE moderation_commands
           SET state = 'conflict', execution_fence = NULL,
               execution_lease_until = NULL,
               provider_state_observed = 0, causality_proven = 0,
               result_code = 'VOICE_CONTROL_CONFLICT', finalized_at = ?
           WHERE state IN ('executing', 'pending_observation')
             AND attempt_started_at IS NOT NULL
             AND attempt_started_at <= ?
             AND (
               execution_lease_until IS NULL OR execution_lease_until <= ?
             )`,
          now,
          cutoff,
          nowMs,
        );
      }
      this.ctx.storage.sql.exec(
        `UPDATE moderation_outbox
         SET state = 'dispatched', dispatched_at = COALESCE(dispatched_at, ?)
         WHERE command_id IN (
           SELECT command_id
           FROM moderation_commands
           WHERE state IN ('unsupported', 'conflict')
             AND finalized_at = ?
         )`,
        now,
        now,
      );
      return unattempted.length + attempted.length;
    });
  }

  private markOutboxTerminal(commandId: string, now: string): void {
    this.ctx.storage.sql.exec(
      `UPDATE moderation_outbox
       SET state = 'dispatched', dispatched_at = COALESCE(dispatched_at, ?)
       WHERE command_id = ?`,
      now,
      commandId,
    );
  }

  private async scheduleNextModerationAlarm(nowMs: number): Promise<void> {
    if (this.pendingOutboxCount() > 0) {
      await this.ctx.storage.setAlarm(nowMs + OUTBOX_CONTINUATION_DELAY_MS);
      return;
    }

    const pending = this.ctx.storage.sql
      .exec<PendingCommandDeadlineRow>(
        `SELECT created_at, attempt_started_at, state, execution_lease_until
         FROM moderation_commands
         WHERE state IN ('pending', 'executing', 'pending_observation')`,
      )
      .toArray();
    if (pending.length === 0) {
      await this.ctx.storage.deleteAlarm();
      return;
    }

    const earliestDeadline = pending.reduce((earliest, command) => {
      const deadlineOrigin =
        command.state === "pending"
          ? command.created_at
          : (command.attempt_started_at ?? command.created_at);
      const createdAt = Date.parse(deadlineOrigin);
      const terminalDeadline =
        (Number.isFinite(createdAt) ? createdAt : nowMs) +
        COMMAND_TERMINAL_DEADLINE_MS;
      const leaseSafeDeadline =
        command.execution_lease_until !== null
          ? Math.max(
              terminalDeadline,
              command.execution_lease_until + OUTBOX_CONTINUATION_DELAY_MS,
            )
          : terminalDeadline;
      return Math.min(earliest, leaseSafeDeadline);
    }, Number.POSITIVE_INFINITY);
    await this.ctx.storage.setAlarm(
      Math.max(
        nowMs + OUTBOX_CONTINUATION_DELAY_MS,
        earliestDeadline,
      ),
    );
  }

  private recordOutboxAttempt(
    rows: ModerationOutboxRow[],
    attemptedAt: string,
  ): void {
    this.ctx.storage.transactionSync(() => {
      for (const row of rows) {
        this.ctx.storage.sql.exec(
          `UPDATE moderation_outbox
           SET dispatch_attempts = dispatch_attempts + 1, last_attempt_at = ?
           WHERE command_id = ? AND state = 'pending'`,
          attemptedAt,
          row.command_id,
        );
      }
    });
  }

  private markOutboxDispatched(
    rows: ModerationOutboxRow[],
    dispatchedAt: string,
  ): void {
    this.ctx.storage.transactionSync(() => {
      for (const row of rows) {
        this.ctx.storage.sql.exec(
          `UPDATE moderation_outbox
           SET state = 'dispatched', dispatched_at = ?
           WHERE command_id = ? AND state = 'pending'`,
          dispatchedAt,
          row.command_id,
        );
      }
    });
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
  const record: ModerationCommandRecord = {
    commandId: row.command_id,
    action: row.action,
    targetPrincipalId: row.target_principal_id,
    controlRevision: row.result_revision,
    status: row.state,
    providerRequestAccepted: row.provider_request_accepted === 1,
    providerStateObserved: row.provider_state_observed === 1,
    causalityProven: false,
    resultCode: row.result_code,
    createdAt: row.created_at,
    finalizedAt: row.finalized_at,
  };
  if (
    row.state === "pending" ||
    row.state === "unsupported" ||
    row.state === "conflict"
  ) {
    record.providerMutationApplied = false;
  }
  return record;
}

function isTerminalModerationState(
  state: ModerationCommandRow["state"],
): boolean {
  return (
    state === "desired_state_observed" ||
    state === "conflict" ||
    state === "unsupported"
  );
}

function outboxEnvelope(
  row: ModerationOutboxRow,
): VoiceControlQueueEnvelope {
  return {
    schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
    roomId: row.room_id,
    commandId: row.command_id,
    controlRevision: row.result_revision,
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

import { DurableObject } from "cloudflare:workers";
import type {
  RoomRecord,
  SentiMembershipRole,
  VoiceRole,
} from "./contracts";
import {
  canonicalUtcDay,
  isCanonicalUtcInstant,
} from "./canonical-time";
import type { RuntimeEnv } from "./env";
import { HttpError } from "./errors";
import {
  deriveParticipantId,
  deriveProviderIdentityKey,
} from "./identity";
import {
  providerIdentityShardIndex,
  providerIdentityShardName,
  type AdmissionQuotaPinResult,
  type ProviderIdentityClaimResult,
} from "./room-provider-identity-shard";

export const ADMISSION_SHARD_COUNT = 64;
export const MAX_ADMISSIONS_PER_SHARD = 4_096;
export const MAX_DAILY_ADMISSIONS_PER_ROOM = 100_000;

const ADMISSION_LEASE_MS = 15_000;
const BASE64_URL =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
const PARTICIPANT_KEY = /^senti_[A-Za-z0-9_-]{43}$/;
const PRINCIPAL_ID = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,159}$/;
const OPAQUE_PROVIDER_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface AdmissionRoomPrimeInput {
  room: RoomRecord;
  shardIndex: number;
  now: string;
  maxDailyAdmissionsPerRoom: number;
}

export interface AdmissionRoomEndInput {
  room: RoomRecord;
  shardIndex: number;
  now: string;
}

export interface AdmissionReservationInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  shardIndex: number;
  participantKey: string;
  principalId: string;
  membershipRole: SentiMembershipRole;
  desiredRole: VoiceRole;
  displayName: string;
  now: string;
}

export interface AdmissionCompletionInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  shardIndex: number;
  participantKey: string;
  fence: string;
  providerParticipantId: string;
  now: string;
}

export interface AdmissionFenceInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  shardIndex: number;
  participantKey: string;
  fence: string;
  now: string;
}

export interface AdmissionLookupInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  shardIndex: number;
  participantKey: string;
  principalId: string;
}

export interface ActiveAdmission {
  participantKey: string;
  principalId: string;
  admissionRevision: number;
  membershipRole: SentiMembershipRole;
  role: VoiceRole;
  displayName: string;
  providerParticipantId: string;
  updatedAt: string;
}

export interface AdmissionRoomSnapshot {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  shardIndex: number;
  providerMeetingId: string;
  lifecycle: "ready" | "ended";
  controlRevisionFloor: number;
  maxDailyAdmissionsPerRoom: number;
  transcriptMode: "post-meeting";
}

export type AdmissionPrimeResult =
  | {
      disposition: "ready";
      room: AdmissionRoomSnapshot;
    }
  | { disposition: "room_ended" }
  | { disposition: "identity_mismatch" }
  | { disposition: "quota_mismatch" }
  | { disposition: "quota_unavailable" }
  | { disposition: "invalid" };

export type AdmissionEndResult =
  | { disposition: "ended"; room: AdmissionRoomSnapshot }
  | { disposition: "room_not_ready" }
  | { disposition: "identity_mismatch" }
  | { disposition: "invalid" };

export type ShardedAdmissionReservation =
  | {
      disposition: "create" | "refresh" | "update";
      fence: string;
      attemptId: string;
      providerParticipantId: string | null;
      room: AdmissionRoomSnapshot;
    }
  | {
      disposition: "reconciliation_required";
      attemptId: string;
      room: AdmissionRoomSnapshot;
    }
  | { disposition: "busy" }
  | { disposition: "room_not_ready" }
  | { disposition: "identity_mismatch" }
  | { disposition: "principal_conflict" }
  | { disposition: "identity_unavailable" }
  | { disposition: "over_budget" }
  | { disposition: "capacity" }
  | { disposition: "invalid" };

export type AdmissionCompletionResult =
  | { disposition: "applied"; admission: ActiveAdmission }
  | { disposition: "invalid_fence" }
  | { disposition: "room_not_ready" }
  | { disposition: "identity_mismatch" }
  | { disposition: "provider_identity_conflict" }
  | { disposition: "provider_identity_capacity" }
  | { disposition: "provider_identity_unavailable" }
  | { disposition: "invalid" };

export type AdmissionFenceResult =
  | { disposition: "released" }
  | { disposition: "reconciliation_required"; attemptId: string }
  | { disposition: "invalid_fence" }
  | { disposition: "identity_mismatch" }
  | { disposition: "invalid" };

export type AdmissionLookupResult =
  | {
      disposition: "active";
      room: AdmissionRoomSnapshot;
      admission: ActiveAdmission;
    }
  | { disposition: "not_found" }
  | { disposition: "room_not_ready" }
  | { disposition: "identity_mismatch" }
  | { disposition: "invalid" };

interface AdmissionRoomRow {
  [key: string]: SqlStorageValue;
  singleton: 1;
  tenant_id: string;
  senti_session_id: string;
  room_epoch: string;
  room_id: string;
  shard_index: number;
  provider_meeting_id: string;
  lifecycle: "ready" | "ended";
  control_revision_floor: number;
  max_daily_admissions_per_room: number | null;
  transcript_mode: "post-meeting";
  created_at: string;
  updated_at: string;
}

interface AdmissionRow {
  [key: string]: SqlStorageValue;
  participant_key: string;
  principal_id: string;
  membership_role: SentiMembershipRole;
  role: VoiceRole | null;
  pending_role: VoiceRole | null;
  display_name: string | null;
  pending_display_name: string | null;
  provider_participant_id: string | null;
  pending_provider_participant_id: string | null;
  revision: number;
  state: "provisioning" | "active" | "reconciling";
  fence: string | null;
  attempt_id: string | null;
  completed_fence: string | null;
  completed_attempt_id: string | null;
  lease_until: number | null;
  created_at: string;
  updated_at: string;
}

interface AdmissionUsageRow {
  [key: string]: SqlStorageValue;
  usage_day: string;
  admission_requests: number;
  updated_at: string;
}

type AdmissionCompletionPreparation =
  | {
      disposition: "pending";
      room: AdmissionRoomRow;
      admission: AdmissionRow;
    }
  | AdmissionCompletionResult;

export class RoomAdmissionShard extends DurableObject<RuntimeEnv> {
  constructor(ctx: DurableObjectState, env: RuntimeEnv) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS admission_room (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          tenant_id TEXT NOT NULL,
          senti_session_id TEXT NOT NULL,
          room_epoch TEXT NOT NULL,
          room_id TEXT NOT NULL,
          shard_index INTEGER NOT NULL,
          provider_meeting_id TEXT NOT NULL,
          lifecycle TEXT NOT NULL,
          control_revision_floor INTEGER NOT NULL,
          max_daily_admissions_per_room INTEGER,
          transcript_mode TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK (control_revision_floor >= 0),
          CHECK (
            max_daily_admissions_per_room IS NULL OR (
              max_daily_admissions_per_room >= 1 AND
              max_daily_admissions_per_room <= 100000
            )
          ),
          CHECK (shard_index >= 0 AND shard_index < 64),
          CHECK (lifecycle IN ('ready', 'ended')),
          CHECK (transcript_mode = 'post-meeting')
        );
        CREATE TABLE IF NOT EXISTS admissions (
          participant_key TEXT PRIMARY KEY,
          principal_id TEXT NOT NULL UNIQUE,
          membership_role TEXT NOT NULL,
          role TEXT,
          pending_role TEXT,
          display_name TEXT,
          pending_display_name TEXT,
          provider_participant_id TEXT,
          pending_provider_participant_id TEXT,
          revision INTEGER NOT NULL,
          state TEXT NOT NULL,
          fence TEXT,
          attempt_id TEXT,
          completed_fence TEXT,
          completed_attempt_id TEXT,
          lease_until INTEGER,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK (membership_role IN ('owner', 'admin', 'contributor', 'viewer')),
          CHECK (role IS NULL OR role IN ('moderator', 'speaker', 'listener')),
          CHECK (
            pending_role IS NULL OR
            pending_role IN ('moderator', 'speaker', 'listener')
          ),
          CHECK (state IN ('provisioning', 'active', 'reconciling')),
          CHECK (revision >= 1),
          CHECK (
            (completed_fence IS NULL AND completed_attempt_id IS NULL) OR
            (completed_fence IS NOT NULL AND completed_attempt_id IS NOT NULL)
          ),
          CHECK (
            (state = 'active' AND role IS NOT NULL
              AND pending_role IS NULL AND pending_display_name IS NULL
              AND pending_provider_participant_id IS NULL
              AND provider_participant_id IS NOT NULL
              AND fence IS NULL AND attempt_id IS NULL AND lease_until IS NULL)
            OR
            (state = 'provisioning' AND pending_role IS NOT NULL
              AND pending_display_name IS NOT NULL
              AND fence IS NOT NULL AND attempt_id IS NOT NULL
              AND completed_fence IS NULL AND completed_attempt_id IS NULL
              AND lease_until IS NOT NULL)
            OR
            (state = 'reconciling' AND pending_role IS NOT NULL
              AND pending_display_name IS NOT NULL
              AND completed_fence IS NULL AND completed_attempt_id IS NULL
              AND fence IS NOT NULL AND attempt_id IS NOT NULL)
          )
        );
        CREATE UNIQUE INDEX IF NOT EXISTS admissions_provider_participant
          ON admissions(provider_participant_id)
          WHERE provider_participant_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS admissions_state
          ON admissions(state, updated_at);
        CREATE TABLE IF NOT EXISTS admission_daily_usage (
          usage_day TEXT PRIMARY KEY,
          admission_requests INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT NOT NULL,
          CHECK (admission_requests >= 0)
        );
      `);
      ensureAdmissionRoomQuotaColumn(this.ctx.storage.sql);
      ensureAdmissionCompletionColumns(this.ctx.storage.sql);
    });
  }

  async primeRoom(
    input: AdmissionRoomPrimeInput,
  ): Promise<AdmissionPrimeResult> {
    if (
      !validPrime(input) ||
      !this.isExpectedObject({
        roomId: input.room.roomId,
        shardIndex: input.shardIndex,
      })
    ) {
      return { disposition: "invalid" };
    }
    const localBlock = this.ctx.storage.transactionSync(
      (): AdmissionPrimeResult | null => {
        const existing = this.room();
        if (
          existing &&
          !matchesRoomRecord(
            existing,
            input.room,
            input.shardIndex,
          )
        ) {
          return { disposition: "identity_mismatch" };
        }
        if (
          existing &&
          (existing.max_daily_admissions_per_room === null ||
            existing.max_daily_admissions_per_room !==
              input.maxDailyAdmissionsPerRoom)
        ) {
          return { disposition: "quota_mismatch" };
        }
        if (existing?.lifecycle === "ended") {
          return { disposition: "room_ended" };
        }
        return null;
      },
    );
    if (localBlock) return localBlock;

    let quotaPin: AdmissionQuotaPinResult;
    try {
      quotaPin = await this.env.ROOM_PROVIDER_IDENTITY_SHARDS
        .getByName(providerIdentityShardName(input.room.roomId, 0))
        .pinAdmissionQuota({
          tenantId: input.room.tenantId,
          sessionId: input.room.sessionId,
          roomEpoch: input.room.roomEpoch,
          roomId: input.room.roomId,
          providerMeetingId: input.room.providerMeetingId,
          maxDailyAdmissionsPerRoom:
            input.maxDailyAdmissionsPerRoom,
          now: input.now,
        });
    } catch {
      return { disposition: "quota_unavailable" };
    }
    if (quotaPin.disposition === "quota_mismatch") {
      return { disposition: "quota_mismatch" };
    }
    if (quotaPin.disposition === "identity_mismatch") {
      return { disposition: "identity_mismatch" };
    }
    if (quotaPin.disposition !== "ready") {
      return { disposition: "quota_unavailable" };
    }

    return this.ctx.storage.transactionSync(() => {
      const existing = this.room();
      if (
        existing &&
        !matchesRoomRecord(existing, input.room, input.shardIndex)
      ) {
        return { disposition: "identity_mismatch" };
      }
      if (
        existing &&
        (existing.max_daily_admissions_per_room === null ||
          existing.max_daily_admissions_per_room !==
            input.maxDailyAdmissionsPerRoom)
      ) {
        return { disposition: "quota_mismatch" };
      }
      if (existing?.lifecycle === "ended") {
        return { disposition: "room_ended" };
      }
      if (!existing) {
        this.ctx.storage.sql.exec(
          `INSERT INTO admission_room (
             singleton, tenant_id, senti_session_id, room_epoch, room_id,
             shard_index, provider_meeting_id, lifecycle,
             control_revision_floor, max_daily_admissions_per_room,
             transcript_mode, created_at, updated_at
           ) VALUES (1, ?, ?, ?, ?, ?, ?, 'ready', ?, ?, ?, ?, ?)`,
          input.room.tenantId,
          input.room.sessionId,
          input.room.roomEpoch,
          input.room.roomId,
          input.shardIndex,
          input.room.providerMeetingId,
          input.room.controlRevision,
          input.maxDailyAdmissionsPerRoom,
          input.room.transcriptMode,
          input.now,
          input.now,
        );
      } else if (
        input.room.controlRevision > existing.control_revision_floor
      ) {
        this.ctx.storage.sql.exec(
          `UPDATE admission_room
           SET control_revision_floor = ?, updated_at = ?
           WHERE singleton = 1 AND control_revision_floor < ?`,
          input.room.controlRevision,
          input.now,
          input.room.controlRevision,
        );
      }
      return {
        disposition: "ready",
        room: toRoomSnapshot(this.roomRequired()),
      };
    });
  }

  endRoom(input: AdmissionRoomEndInput): AdmissionEndResult {
    return this.ctx.storage.transactionSync(() => {
      if (
        !validEnd(input) ||
        !this.isExpectedObject({
          roomId: input.room.roomId,
          shardIndex: input.shardIndex,
        })
      ) {
        return { disposition: "invalid" };
      }
      const existing = this.room();
      if (
        !existing ||
        existing.max_daily_admissions_per_room === null
      ) {
        return { disposition: "room_not_ready" };
      }
      if (!matchesRoomRecord(existing, input.room, input.shardIndex)) {
        return { disposition: "identity_mismatch" };
      }
      this.ctx.storage.sql.exec(
        `UPDATE admission_room
         SET lifecycle = 'ended',
             control_revision_floor = MAX(control_revision_floor, ?),
             updated_at = ?
         WHERE singleton = 1`,
        input.room.controlRevision,
        input.now,
      );
      return {
        disposition: "ended",
        room: toRoomSnapshot(this.roomRequired()),
      };
    });
  }

  async reserveAdmission(
    input: AdmissionReservationInput,
  ): Promise<ShardedAdmissionReservation> {
    if (!validReservation(input) || !this.isExpectedObject(input)) {
      return { disposition: "invalid" };
    }
    let expectedParticipantKey: string;
    try {
      expectedParticipantKey = await deriveParticipantId(
        this.env.IDENTITY_HMAC_SECRET,
        input.roomId,
        input.principalId,
      );
    } catch {
      return { disposition: "identity_unavailable" };
    }
    if (expectedParticipantKey !== input.participantKey) {
      return { disposition: "invalid" };
    }

    return this.ctx.storage.transactionSync(() => {
      const room = this.room();
      if (
        !room ||
        room.lifecycle !== "ready" ||
        room.max_daily_admissions_per_room === null
      ) {
        return { disposition: "room_not_ready" };
      }
      if (!matchesRoomInput(room, input)) {
        return { disposition: "identity_mismatch" };
      }

      const existing = this.admission(input.participantKey);
      const principal = this.admissionByPrincipal(input.principalId);
      if (
        (existing && existing.principal_id !== input.principalId) ||
        (principal && principal.participant_key !== input.participantKey)
      ) {
        return { disposition: "principal_conflict" };
      }

      const nowMs = Date.parse(input.now);
      if (existing?.state === "reconciling") {
        return {
          disposition: "reconciliation_required",
          attemptId: existing.attempt_id!,
          room: toRoomSnapshot(room),
        };
      }
      if (existing?.state === "provisioning") {
        if (existing.lease_until !== null && existing.lease_until > nowMs) {
          return { disposition: "busy" };
        }
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET state = 'reconciling', lease_until = NULL, updated_at = ?
           WHERE participant_key = ? AND state = 'provisioning'`,
          input.now,
          input.participantKey,
        );
        return {
          disposition: "reconciliation_required",
          attemptId: existing.attempt_id!,
          room: toRoomSnapshot(room),
        };
      }

      if (
        !existing &&
        this.admissionCount() >= MAX_ADMISSIONS_PER_SHARD
      ) {
        return { disposition: "capacity" };
      }
      if (
        !this.consumeAdmissionRequest(
          input.now,
          admissionShardDailyLimit(
            room.max_daily_admissions_per_room,
            input.shardIndex,
          ),
        )
      ) {
        return { disposition: "over_budget" };
      }

      const fence = crypto.randomUUID();
      const attemptId = crypto.randomUUID();
      const disposition =
        !existing || !existing.provider_participant_id
          ? "create"
          : existing.role === input.desiredRole
            ? "refresh"
            : "update";
      if (existing) {
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET membership_role = ?, pending_role = ?,
               pending_display_name = ?, state = 'provisioning',
               fence = ?, attempt_id = ?, lease_until = ?,
               pending_provider_participant_id = NULL,
               completed_fence = NULL, completed_attempt_id = NULL,
               revision = revision + 1, updated_at = ?
           WHERE participant_key = ? AND state = 'active'`,
          input.membershipRole,
          input.desiredRole,
          input.displayName,
          fence,
          attemptId,
          nowMs + ADMISSION_LEASE_MS,
          input.now,
          input.participantKey,
        );
      } else {
        this.ctx.storage.sql.exec(
          `INSERT INTO admissions (
             participant_key, principal_id, membership_role, role,
             pending_role, display_name, pending_display_name,
             provider_participant_id, revision, state, fence, attempt_id,
             lease_until, created_at, updated_at
           ) VALUES (
             ?, ?, ?, NULL, ?, NULL, ?, NULL, 1, 'provisioning',
             ?, ?, ?, ?, ?
           )`,
          input.participantKey,
          input.principalId,
          input.membershipRole,
          input.desiredRole,
          input.displayName,
          fence,
          attemptId,
          nowMs + ADMISSION_LEASE_MS,
          input.now,
          input.now,
        );
      }
      return {
        disposition,
        fence,
        attemptId,
        providerParticipantId:
          existing?.provider_participant_id ?? null,
        room: toRoomSnapshot(room),
      };
    });
  }

  async completeAdmission(
    input: AdmissionCompletionInput,
  ): Promise<AdmissionCompletionResult> {
    const prepared = this.ctx.storage.transactionSync(() =>
      this.prepareCompletion(input, true),
    );
    if (prepared.disposition !== "pending") return prepared;

    const providerIdentityKey = await deriveProviderIdentityKey(
      input.roomId,
      input.providerParticipantId,
    );
    const providerIdentityShard = providerIdentityShardIndex(
      providerIdentityKey,
    );
    let identityClaim: ProviderIdentityClaimResult;
    try {
      identityClaim = await this.env.ROOM_PROVIDER_IDENTITY_SHARDS
        .getByName(
          providerIdentityShardName(
            input.roomId,
            providerIdentityShard,
          ),
        )
        .claimProviderIdentity({
          tenantId: prepared.room.tenant_id,
          sessionId: prepared.room.senti_session_id,
          roomEpoch: prepared.room.room_epoch,
          roomId: prepared.room.room_id,
          providerMeetingId: prepared.room.provider_meeting_id,
          shardIndex: providerIdentityShard,
          providerIdentityKey,
          providerParticipantId: input.providerParticipantId,
          participantKey: prepared.admission.participant_key,
          principalId: prepared.admission.principal_id,
          attemptId: prepared.admission.attempt_id!,
          now: input.now,
        });
    } catch {
      return { disposition: "provider_identity_unavailable" };
    }
    if (
      identityClaim.disposition === "provider_identity_conflict"
    ) {
      return { disposition: "provider_identity_conflict" };
    }
    if (identityClaim.disposition === "capacity") {
      return { disposition: "provider_identity_capacity" };
    }
    if (
      identityClaim.disposition !== "claimed" &&
      identityClaim.disposition !== "replay"
    ) {
      return { disposition: "provider_identity_unavailable" };
    }

    return this.ctx.storage.transactionSync(() => {
      const current = this.prepareCompletion(input, false);
      if (current.disposition !== "pending") return current;
      if (
        current.admission.attempt_id !==
          prepared.admission.attempt_id ||
        current.admission.principal_id !==
          prepared.admission.principal_id
      ) {
        return { disposition: "invalid_fence" };
      }
      this.ctx.storage.sql.exec(
        `UPDATE admissions
         SET role = pending_role, pending_role = NULL,
             display_name = pending_display_name,
             pending_display_name = NULL,
             provider_participant_id = ?,
             pending_provider_participant_id = NULL,
             state = 'active',
             completed_fence = fence,
             completed_attempt_id = attempt_id,
             fence = NULL, attempt_id = NULL, lease_until = NULL,
             updated_at = ?
         WHERE participant_key = ? AND fence = ?
           AND pending_provider_participant_id = ?
           AND state IN ('provisioning', 'reconciling')`,
        input.providerParticipantId,
        input.now,
        input.participantKey,
        input.fence,
        input.providerParticipantId,
      );
      const completed = this.admission(input.participantKey);
      if (!completed || completed.state !== "active") {
        return { disposition: "invalid_fence" };
      }
      return {
        disposition: "applied",
        admission: toActiveAdmission(completed),
      };
    });
  }

  releaseKnownFailure(input: AdmissionFenceInput): AdmissionFenceResult {
    return this.ctx.storage.transactionSync(() => {
      const validated = this.validateFenceInput(input, true);
      if (validated !== "ok") return { disposition: validated };
      const admission = this.admission(input.participantKey)!;
      if (admission.pending_provider_participant_id !== null) {
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET state = 'reconciling', lease_until = NULL, updated_at = ?
           WHERE participant_key = ? AND fence = ?
             AND state IN ('provisioning', 'reconciling')`,
          input.now,
          input.participantKey,
          input.fence,
        );
        return {
          disposition: "reconciliation_required",
          attemptId: admission.attempt_id!,
        };
      }
      if (admission.state === "reconciling") {
        return { disposition: "invalid_fence" };
      }
      if (admission.provider_participant_id && admission.role) {
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET pending_role = NULL, pending_display_name = NULL,
               state = 'active', fence = NULL, attempt_id = NULL,
               lease_until = NULL, updated_at = ?
           WHERE participant_key = ? AND fence = ?
             AND state IN ('provisioning', 'reconciling')`,
          input.now,
          input.participantKey,
          input.fence,
        );
      } else {
        this.ctx.storage.sql.exec(
          `DELETE FROM admissions
           WHERE participant_key = ? AND fence = ?
             AND state IN ('provisioning', 'reconciling')`,
          input.participantKey,
          input.fence,
        );
      }
      return { disposition: "released" };
    });
  }

  markOutcomeUncertain(input: AdmissionFenceInput): AdmissionFenceResult {
    return this.ctx.storage.transactionSync(() => {
      const validated = this.validateFenceInput(input, true);
      if (validated !== "ok") return { disposition: validated };
      const admission = this.admission(input.participantKey)!;
      this.ctx.storage.sql.exec(
        `UPDATE admissions
         SET state = 'reconciling', lease_until = NULL, updated_at = ?
         WHERE participant_key = ? AND fence = ?
           AND state IN ('provisioning', 'reconciling')`,
        input.now,
        input.participantKey,
        input.fence,
      );
      return {
        disposition: "reconciliation_required",
        attemptId: admission.attempt_id!,
      };
    });
  }

  resolveReconciledAbsent(
    input: AdmissionFenceInput,
  ): AdmissionFenceResult {
    return this.ctx.storage.transactionSync(() => {
      const validated = this.validateFenceInput(input, true);
      if (validated !== "ok") return { disposition: validated };
      const admission = this.admission(input.participantKey)!;
      if (admission.state !== "reconciling") {
        return { disposition: "invalid_fence" };
      }
      if (admission.pending_provider_participant_id !== null) {
        return {
          disposition: "reconciliation_required",
          attemptId: admission.attempt_id!,
        };
      }
      if (admission.provider_participant_id && admission.role) {
        this.ctx.storage.sql.exec(
          `UPDATE admissions
           SET pending_role = NULL, pending_display_name = NULL,
               state = 'active', fence = NULL, attempt_id = NULL,
               lease_until = NULL, updated_at = ?
           WHERE participant_key = ? AND fence = ?
             AND state = 'reconciling'`,
          input.now,
          input.participantKey,
          input.fence,
        );
      } else {
        this.ctx.storage.sql.exec(
          `DELETE FROM admissions
           WHERE participant_key = ? AND fence = ?
             AND state = 'reconciling'`,
          input.participantKey,
          input.fence,
        );
      }
      return { disposition: "released" };
    });
  }

  lookupActive(input: AdmissionLookupInput): AdmissionLookupResult {
    if (!validLookup(input) || !this.isExpectedObject(input)) {
      return { disposition: "invalid" };
    }
    const room = this.room();
    if (
      !room ||
      room.max_daily_admissions_per_room === null ||
      !matchesRoomInput(room, input)
    ) {
      return { disposition: "identity_mismatch" };
    }
    if (room.lifecycle !== "ready") {
      return { disposition: "room_not_ready" };
    }
    const admission = this.admission(input.participantKey);
    if (
      !admission ||
      admission.principal_id !== input.principalId ||
      admission.state !== "active"
    ) {
      return { disposition: "not_found" };
    }
    return {
      disposition: "active",
      room: toRoomSnapshot(room),
      admission: toActiveAdmission(admission),
    };
  }

  debugSnapshot(): {
    room: AdmissionRoomSnapshot | null;
    admissions: Array<{
      participantKey: string;
      principalId: string;
      membershipRole: SentiMembershipRole;
      role: VoiceRole | null;
      pendingRole: VoiceRole | null;
      providerParticipantId: string | null;
      pendingProviderParticipantId: string | null;
      admissionRevision: number;
      state: AdmissionRow["state"];
      attemptId: string | null;
      completedFence: string | null;
      completedAttemptId: string | null;
      leaseUntil: number | null;
    }>;
    dailyUsage: Array<{ day: string; requests: number }>;
  } {
    return {
      room: this.room() ? toRoomSnapshot(this.roomRequired()) : null,
      admissions: this.ctx.storage.sql
        .exec<AdmissionRow>(
          `SELECT * FROM admissions
           ORDER BY participant_key`,
        )
        .toArray()
        .map((row) => ({
          participantKey: row.participant_key,
          principalId: row.principal_id,
          membershipRole: row.membership_role,
          role: row.role,
          pendingRole: row.pending_role,
          providerParticipantId: row.provider_participant_id,
          pendingProviderParticipantId:
            row.pending_provider_participant_id,
          admissionRevision: row.revision,
          state: row.state,
          attemptId: row.attempt_id,
          completedFence: row.completed_fence,
          completedAttemptId: row.completed_attempt_id,
          leaseUntil: row.lease_until,
        })),
      dailyUsage: this.ctx.storage.sql
        .exec<AdmissionUsageRow>(
          `SELECT * FROM admission_daily_usage
           ORDER BY usage_day`,
        )
        .toArray()
        .map((row) => ({
          day: row.usage_day,
          requests: row.admission_requests,
        })),
    };
  }

  private prepareCompletion(
    input: AdmissionCompletionInput,
    pinProviderIntent: boolean,
  ): AdmissionCompletionPreparation {
    if (!validCompletion(input) || !this.isExpectedObject(input)) {
      return { disposition: "invalid" };
    }
    const room = this.room();
    if (!room || !matchesRoomInput(room, input)) {
      return { disposition: "identity_mismatch" };
    }
    if (room.max_daily_admissions_per_room === null) {
      return { disposition: "room_not_ready" };
    }

    let admission = this.admission(input.participantKey);
    if (
      admission?.state === "active" &&
      admission.completed_fence === input.fence &&
      admission.provider_participant_id ===
        input.providerParticipantId
    ) {
      return {
        disposition: "applied",
        admission: toActiveAdmission(admission),
      };
    }
    if (room.lifecycle !== "ready") {
      return { disposition: "room_not_ready" };
    }
    if (
      !admission ||
      (admission.state !== "provisioning" &&
        admission.state !== "reconciling") ||
      admission.fence !== input.fence ||
      !admission.pending_role ||
      !admission.pending_display_name
    ) {
      return { disposition: "invalid_fence" };
    }
    if (
      (admission.provider_participant_id &&
        admission.provider_participant_id !==
          input.providerParticipantId) ||
      (admission.pending_provider_participant_id &&
        admission.pending_provider_participant_id !==
          input.providerParticipantId)
    ) {
      return { disposition: "provider_identity_conflict" };
    }
    const providerOwner = this.admissionByProviderParticipant(
      input.providerParticipantId,
    );
    if (
      providerOwner &&
      providerOwner.participant_key !== input.participantKey
    ) {
      return { disposition: "provider_identity_conflict" };
    }
    if (
      pinProviderIntent &&
      admission.pending_provider_participant_id === null
    ) {
      this.ctx.storage.sql.exec(
        `UPDATE admissions
         SET pending_provider_participant_id = ?, updated_at = ?
         WHERE participant_key = ? AND fence = ?
           AND pending_provider_participant_id IS NULL
           AND state IN ('provisioning', 'reconciling')`,
        input.providerParticipantId,
        input.now,
        input.participantKey,
        input.fence,
      );
      admission = this.admission(input.participantKey);
      if (
        !admission ||
        admission.pending_provider_participant_id !==
          input.providerParticipantId
      ) {
        return { disposition: "invalid_fence" };
      }
    }
    return { disposition: "pending", room, admission };
  }

  private validateFenceInput(
    input: AdmissionFenceInput,
    allowReconciling: boolean,
  ):
    | "ok"
    | "invalid"
    | "identity_mismatch"
    | "invalid_fence" {
    if (!validFence(input) || !this.isExpectedObject(input)) {
      return "invalid";
    }
    const room = this.room();
    if (!room || !matchesRoomInput(room, input)) {
      return "identity_mismatch";
    }
    const admission = this.admission(input.participantKey);
    if (
      !admission ||
      (admission.state !== "provisioning" &&
        !(allowReconciling && admission.state === "reconciling")) ||
      admission.fence !== input.fence
    ) {
      return "invalid_fence";
    }
    return "ok";
  }

  private isExpectedObject(input: {
    roomId: string;
    shardIndex: number;
  }): boolean {
    try {
      return this.ctx.id.equals(
        this.env.ROOM_ADMISSION_SHARDS.idFromName(
          admissionShardName(input.roomId, input.shardIndex),
        ),
      );
    } catch {
      return false;
    }
  }

  private consumeAdmissionRequest(now: string, maximum: number): boolean {
    if (maximum < 1) return false;
    const day = canonicalUtcDay(now);
    const existing = this.ctx.storage.sql
      .exec<AdmissionUsageRow>(
        `SELECT * FROM admission_daily_usage
         WHERE usage_day = ?`,
        day,
      )
      .toArray()[0];
    if (existing && existing.admission_requests >= maximum) return false;
    if (existing) {
      this.ctx.storage.sql.exec(
        `UPDATE admission_daily_usage
         SET admission_requests = admission_requests + 1, updated_at = ?
         WHERE usage_day = ?`,
        now,
        day,
      );
    } else {
      this.ctx.storage.sql.exec(
        `INSERT INTO admission_daily_usage (
           usage_day, admission_requests, updated_at
         ) VALUES (?, 1, ?)`,
        day,
        now,
      );
    }
    return true;
  }

  private admissionCount(): number {
    return this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM admissions",
      )
      .one().count;
  }

  private room(): AdmissionRoomRow | null {
    return (
      this.ctx.storage.sql
        .exec<AdmissionRoomRow>(
          "SELECT * FROM admission_room WHERE singleton = 1",
        )
        .toArray()[0] ?? null
    );
  }

  private roomRequired(): AdmissionRoomRow {
    return this.ctx.storage.sql
      .exec<AdmissionRoomRow>(
        "SELECT * FROM admission_room WHERE singleton = 1",
      )
      .one();
  }

  private admission(participantKey: string): AdmissionRow | null {
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

  private admissionByProviderParticipant(
    providerParticipantId: string,
  ): AdmissionRow | null {
    return (
      this.ctx.storage.sql
        .exec<AdmissionRow>(
          `SELECT * FROM admissions
           WHERE provider_participant_id = ?`,
          providerParticipantId,
        )
        .toArray()[0] ?? null
    );
  }
}

export function admissionShardIndex(participantKey: string): number {
  if (!PARTICIPANT_KEY.test(participantKey)) throw invalidShard();
  const index = BASE64_URL.indexOf(participantKey[6]!);
  if (index < 0) throw invalidShard();
  return index;
}

export function admissionShardName(
  roomId: string,
  shardIndex: number,
): string {
  if (
    !ROOM_ID.test(roomId) ||
    !Number.isInteger(shardIndex) ||
    shardIndex < 0 ||
    shardIndex >= ADMISSION_SHARD_COUNT
  ) {
    throw invalidShard();
  }
  return `admission:v1:${roomId}:${shardIndex}`;
}

export function admissionShardDailyLimit(
  maximumPerRoom: number,
  shardIndex: number,
): number {
  if (
    !Number.isSafeInteger(maximumPerRoom) ||
    maximumPerRoom < 1 ||
    maximumPerRoom > MAX_DAILY_ADMISSIONS_PER_ROOM ||
    !Number.isInteger(shardIndex) ||
    shardIndex < 0 ||
    shardIndex >= ADMISSION_SHARD_COUNT
  ) {
    throw invalidShard();
  }
  const base = Math.floor(maximumPerRoom / ADMISSION_SHARD_COUNT);
  return base + (shardIndex < maximumPerRoom % ADMISSION_SHARD_COUNT ? 1 : 0);
}

function validPrime(input: AdmissionRoomPrimeInput): boolean {
  return (
    Number.isInteger(input.shardIndex) &&
    input.shardIndex >= 0 &&
    input.shardIndex < ADMISSION_SHARD_COUNT &&
    validRoom(input.room) &&
    validTimestamp(input.now) &&
    Number.isSafeInteger(input.maxDailyAdmissionsPerRoom) &&
    input.maxDailyAdmissionsPerRoom >= 1 &&
    input.maxDailyAdmissionsPerRoom <=
      MAX_DAILY_ADMISSIONS_PER_ROOM
  );
}

function validEnd(input: AdmissionRoomEndInput): boolean {
  return (
    Number.isInteger(input.shardIndex) &&
    input.shardIndex >= 0 &&
    input.shardIndex < ADMISSION_SHARD_COUNT &&
    validRoom(input.room, "ended") &&
    validTimestamp(input.now)
  );
}

function validReservation(input: AdmissionReservationInput): boolean {
  return (
    validRoomInput(input) &&
    PARTICIPANT_KEY.test(input.participantKey) &&
    admissionShardIndex(input.participantKey) === input.shardIndex &&
    PRINCIPAL_ID.test(input.principalId) &&
    validMembershipRole(input.membershipRole) &&
    validVoiceRole(input.desiredRole) &&
    input.displayName.length > 0 &&
    input.displayName.length <= 80 &&
    validTimestamp(input.now)
  );
}

function validCompletion(input: AdmissionCompletionInput): boolean {
  return (
    validFence(input) &&
    OPAQUE_PROVIDER_ID.test(input.providerParticipantId)
  );
}

function validFence(input: AdmissionFenceInput): boolean {
  return (
    validRoomInput(input) &&
    PARTICIPANT_KEY.test(input.participantKey) &&
    admissionShardIndex(input.participantKey) === input.shardIndex &&
    UUID.test(input.fence) &&
    validTimestamp(input.now)
  );
}

function validLookup(input: AdmissionLookupInput): boolean {
  return (
    validRoomInput(input) &&
    PARTICIPANT_KEY.test(input.participantKey) &&
    admissionShardIndex(input.participantKey) === input.shardIndex &&
    PRINCIPAL_ID.test(input.principalId)
  );
}

function validRoomInput(input: {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  shardIndex: number;
}): boolean {
  return (
    OPAQUE_PROVIDER_ID.test(input.tenantId) &&
    UUID.test(input.sessionId) &&
    UUID.test(input.roomEpoch) &&
    ROOM_ID.test(input.roomId) &&
    Number.isInteger(input.shardIndex) &&
    input.shardIndex >= 0 &&
    input.shardIndex < ADMISSION_SHARD_COUNT
  );
}

function validRoom(
  room: RoomRecord,
  lifecycle: "ready" | "ended" = "ready",
): boolean {
  return (
    OPAQUE_PROVIDER_ID.test(room.tenantId) &&
    UUID.test(room.sessionId) &&
    UUID.test(room.roomEpoch) &&
    ROOM_ID.test(room.roomId) &&
    OPAQUE_PROVIDER_ID.test(room.providerMeetingId) &&
    room.lifecycle === lifecycle &&
    Number.isSafeInteger(room.controlRevision) &&
    room.controlRevision >= 0 &&
    room.transcriptMode === "post-meeting" &&
    validTimestamp(room.createdAt) &&
    validTimestamp(room.updatedAt)
  );
}

function validMembershipRole(value: string): value is SentiMembershipRole {
  return (
    value === "owner" ||
    value === "admin" ||
    value === "contributor" ||
    value === "viewer"
  );
}

function validVoiceRole(value: string): value is VoiceRole {
  return (
    value === "moderator" ||
    value === "speaker" ||
    value === "listener"
  );
}

function validTimestamp(value: string): boolean {
  return isCanonicalUtcInstant(value);
}

function matchesRoomRecord(
  row: AdmissionRoomRow,
  room: RoomRecord,
  shardIndex: number,
): boolean {
  return (
    row.tenant_id === room.tenantId &&
    row.senti_session_id === room.sessionId &&
    row.room_epoch === room.roomEpoch &&
    row.room_id === room.roomId &&
    row.shard_index === shardIndex &&
    row.provider_meeting_id === room.providerMeetingId &&
    row.transcript_mode === room.transcriptMode
  );
}

function matchesRoomInput(
  row: AdmissionRoomRow,
  input: {
    tenantId: string;
    sessionId: string;
    roomEpoch: string;
    roomId: string;
    shardIndex: number;
  },
): boolean {
  return (
    row.tenant_id === input.tenantId &&
    row.senti_session_id === input.sessionId &&
    row.room_epoch === input.roomEpoch &&
    row.room_id === input.roomId &&
    row.shard_index === input.shardIndex
  );
}

function toRoomSnapshot(row: AdmissionRoomRow): AdmissionRoomSnapshot {
  if (row.max_daily_admissions_per_room === null) {
    throw new Error("Admission room quota is not pinned.");
  }
  return {
    tenantId: row.tenant_id,
    sessionId: row.senti_session_id,
    roomEpoch: row.room_epoch,
    roomId: row.room_id,
    shardIndex: row.shard_index,
    providerMeetingId: row.provider_meeting_id,
    lifecycle: row.lifecycle,
    controlRevisionFloor: row.control_revision_floor,
    maxDailyAdmissionsPerRoom:
      row.max_daily_admissions_per_room,
    transcriptMode: row.transcript_mode,
  };
}

function toActiveAdmission(row: AdmissionRow): ActiveAdmission {
  if (
    row.state !== "active" ||
    !row.role ||
    !row.display_name ||
    !row.provider_participant_id
  ) {
    throw new Error("Active admission invariant violated.");
  }
  return {
    participantKey: row.participant_key,
    principalId: row.principal_id,
    admissionRevision: row.revision,
    membershipRole: row.membership_role,
    role: row.role,
    displayName: row.display_name,
    providerParticipantId: row.provider_participant_id,
    updatedAt: row.updated_at,
  };
}

function ensureAdmissionRoomQuotaColumn(sql: SqlStorage): void {
  ensureNullableColumn(
    sql,
    "admission_room",
    "max_daily_admissions_per_room",
    `ALTER TABLE admission_room
     ADD COLUMN max_daily_admissions_per_room INTEGER`,
  );
}

function ensureAdmissionCompletionColumns(sql: SqlStorage): void {
  ensureNullableColumn(
    sql,
    "admissions",
    "pending_provider_participant_id",
    `ALTER TABLE admissions
     ADD COLUMN pending_provider_participant_id TEXT`,
  );
  ensureNullableColumn(
    sql,
    "admissions",
    "completed_fence",
    "ALTER TABLE admissions ADD COLUMN completed_fence TEXT",
  );
  ensureNullableColumn(
    sql,
    "admissions",
    "completed_attempt_id",
    "ALTER TABLE admissions ADD COLUMN completed_attempt_id TEXT",
  );
}

function ensureNullableColumn(
  sql: SqlStorage,
  table: string,
  column: string,
  statement: string,
): void {
  const columns = sql
    .exec<{ name: string }>(`PRAGMA table_info(${table})`)
    .toArray();
  if (columns.some((candidate) => candidate.name === column)) return;
  sql.exec(statement);
}

function invalidShard(): HttpError {
  return new HttpError(
    503,
    "invalid_admission_shard",
    "The admission shard identity is invalid.",
  );
}

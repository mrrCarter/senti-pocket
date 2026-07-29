import { DurableObject } from "cloudflare:workers";
import { isCanonicalUtcInstant } from "./canonical-time";
import type { RuntimeEnv } from "./env";
import { HttpError } from "./errors";
import {
  deriveParticipantId,
  deriveProviderIdentityKey,
} from "./identity";

export const PROVIDER_IDENTITY_SHARD_COUNT = 64;
export const MAX_PROVIDER_IDENTITIES_PER_SHARD = 4_096;

const BASE64_URL =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
const PROVIDER_IDENTITY_KEY = /^[A-Za-z0-9_-]{43}$/;
const PARTICIPANT_KEY = /^senti_[A-Za-z0-9_-]{43}$/;
const PRINCIPAL_ID = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,159}$/;
const OPAQUE_PROVIDER_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface ProviderIdentityClaimInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
  shardIndex: number;
  providerIdentityKey: string;
  providerParticipantId: string;
  participantKey: string;
  principalId: string;
  attemptId: string;
  now: string;
}

export interface AdmissionQuotaPinInput {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
  maxDailyAdmissionsPerRoom: number;
  now: string;
}

export type AdmissionQuotaPinResult =
  | { disposition: "ready" }
  | { disposition: "identity_mismatch" }
  | { disposition: "quota_mismatch" }
  | { disposition: "invalid" };

export type ProviderIdentityClaimResult =
  | { disposition: "claimed" | "replay" }
  | { disposition: "identity_mismatch" }
  | { disposition: "identity_unavailable" }
  | { disposition: "provider_identity_conflict" }
  | { disposition: "capacity" }
  | { disposition: "invalid" };

interface ProviderIdentityRoomRow {
  [key: string]: SqlStorageValue;
  singleton: 1;
  tenant_id: string;
  senti_session_id: string;
  room_epoch: string;
  room_id: string;
  provider_meeting_id: string;
  shard_index: number;
  max_daily_admissions_per_room: number | null;
  created_at: string;
  updated_at: string;
}

interface ProviderIdentityClaimRow {
  [key: string]: SqlStorageValue;
  provider_identity_key: string;
  provider_participant_id: string;
  participant_key: string;
  first_attempt_id: string;
  last_attempt_id: string;
  created_at: string;
  updated_at: string;
}

export class RoomProviderIdentityShard extends DurableObject<RuntimeEnv> {
  constructor(ctx: DurableObjectState, env: RuntimeEnv) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS provider_identity_room (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          tenant_id TEXT NOT NULL,
          senti_session_id TEXT NOT NULL,
          room_epoch TEXT NOT NULL,
          room_id TEXT NOT NULL,
          provider_meeting_id TEXT NOT NULL,
          shard_index INTEGER NOT NULL,
          max_daily_admissions_per_room INTEGER,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK (shard_index >= 0 AND shard_index < 64),
          CHECK (
            max_daily_admissions_per_room IS NULL OR (
              max_daily_admissions_per_room >= 1 AND
              max_daily_admissions_per_room <= 100000
            )
          )
        );
        CREATE TABLE IF NOT EXISTS provider_identity_claims (
          provider_identity_key TEXT PRIMARY KEY,
          provider_participant_id TEXT NOT NULL UNIQUE,
          participant_key TEXT NOT NULL,
          first_attempt_id TEXT NOT NULL,
          last_attempt_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS provider_identity_claims_participant
          ON provider_identity_claims(participant_key);
      `);
    });
  }

  pinAdmissionQuota(
    input: AdmissionQuotaPinInput,
  ): AdmissionQuotaPinResult {
    if (
      !validQuotaPin(input) ||
      !this.ctx.id.equals(
        this.env.ROOM_PROVIDER_IDENTITY_SHARDS.idFromName(
          providerIdentityShardName(input.roomId, 0),
        ),
      )
    ) {
      return { disposition: "invalid" };
    }
    return this.ctx.storage.transactionSync(() => {
      const room = this.room();
      if (
        room &&
        !matchesRoomIdentity(room, {
          ...input,
          shardIndex: 0,
        })
      ) {
        return { disposition: "identity_mismatch" };
      }
      if (
        room &&
        room.max_daily_admissions_per_room !== null &&
        room.max_daily_admissions_per_room !==
          input.maxDailyAdmissionsPerRoom
      ) {
        return { disposition: "quota_mismatch" };
      }
      if (!room) {
        this.ctx.storage.sql.exec(
          `INSERT INTO provider_identity_room (
             singleton, tenant_id, senti_session_id, room_epoch, room_id,
             provider_meeting_id, shard_index,
             max_daily_admissions_per_room, created_at, updated_at
           ) VALUES (1, ?, ?, ?, ?, ?, 0, ?, ?, ?)`,
          input.tenantId,
          input.sessionId,
          input.roomEpoch,
          input.roomId,
          input.providerMeetingId,
          input.maxDailyAdmissionsPerRoom,
          input.now,
          input.now,
        );
      } else if (room.max_daily_admissions_per_room === null) {
        this.ctx.storage.sql.exec(
          `UPDATE provider_identity_room
           SET max_daily_admissions_per_room = ?, updated_at = ?
           WHERE singleton = 1
             AND max_daily_admissions_per_room IS NULL`,
          input.maxDailyAdmissionsPerRoom,
          input.now,
        );
      }
      return { disposition: "ready" };
    });
  }

  async claimProviderIdentity(
    input: ProviderIdentityClaimInput,
  ): Promise<ProviderIdentityClaimResult> {
    if (!validClaim(input)) return { disposition: "invalid" };
    const expectedKey = await deriveProviderIdentityKey(
      input.roomId,
      input.providerParticipantId,
    );
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
    if (
      expectedKey !== input.providerIdentityKey ||
      expectedParticipantKey !== input.participantKey ||
      providerIdentityShardIndex(expectedKey) !== input.shardIndex ||
      !this.ctx.id.equals(
        this.env.ROOM_PROVIDER_IDENTITY_SHARDS.idFromName(
          providerIdentityShardName(input.roomId, input.shardIndex),
        ),
      )
    ) {
      return { disposition: "invalid" };
    }

    return this.ctx.storage.transactionSync(() => {
      const room = this.room();
      if (room && !matchesRoomIdentity(room, input)) {
        return { disposition: "identity_mismatch" };
      }

      const existing = this.claim(input.providerIdentityKey);
      const providerOwner = this.claimByProviderParticipant(
        input.providerParticipantId,
      );
      if (
        (existing && !matchesClaim(existing, input)) ||
        (providerOwner &&
          providerOwner.provider_identity_key !==
            input.providerIdentityKey)
      ) {
        return { disposition: "provider_identity_conflict" };
      }
      if (existing) {
        this.ctx.storage.sql.exec(
          `UPDATE provider_identity_claims
           SET last_attempt_id = ?, updated_at = ?
           WHERE provider_identity_key = ?`,
          input.attemptId,
          input.now,
          input.providerIdentityKey,
        );
        return { disposition: "replay" };
      }
      if (
        this.claimCount() >= MAX_PROVIDER_IDENTITIES_PER_SHARD
      ) {
        return { disposition: "capacity" };
      }
      if (!room) {
        this.ctx.storage.sql.exec(
          `INSERT INTO provider_identity_room (
             singleton, tenant_id, senti_session_id, room_epoch, room_id,
             provider_meeting_id, shard_index,
             max_daily_admissions_per_room, created_at, updated_at
           ) VALUES (1, ?, ?, ?, ?, ?, ?, NULL, ?, ?)`,
          input.tenantId,
          input.sessionId,
          input.roomEpoch,
          input.roomId,
          input.providerMeetingId,
          input.shardIndex,
          input.now,
          input.now,
        );
      }
      this.ctx.storage.sql.exec(
        `INSERT INTO provider_identity_claims (
           provider_identity_key, provider_participant_id,
           participant_key, first_attempt_id,
           last_attempt_id, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
        input.providerIdentityKey,
        input.providerParticipantId,
        input.participantKey,
        input.attemptId,
        input.attemptId,
        input.now,
        input.now,
      );
      return { disposition: "claimed" };
    });
  }

  debugSnapshot(): {
    room: {
      tenantId: string;
      sessionId: string;
      roomEpoch: string;
      roomId: string;
      providerMeetingId: string;
      shardIndex: number;
      maxDailyAdmissionsPerRoom: number | null;
    } | null;
    claims: Array<{
      providerIdentityKey: string;
      providerParticipantId: string;
      participantKey: string;
      firstAttemptId: string;
      lastAttemptId: string;
    }>;
  } {
    const room = this.room();
    return {
      room: room
        ? {
            tenantId: room.tenant_id,
            sessionId: room.senti_session_id,
            roomEpoch: room.room_epoch,
            roomId: room.room_id,
            providerMeetingId: room.provider_meeting_id,
            shardIndex: room.shard_index,
            maxDailyAdmissionsPerRoom:
              room.max_daily_admissions_per_room,
          }
        : null,
      claims: this.ctx.storage.sql
        .exec<ProviderIdentityClaimRow>(
          `SELECT * FROM provider_identity_claims
           ORDER BY provider_identity_key`,
        )
        .toArray()
        .map((claim) => ({
          providerIdentityKey: claim.provider_identity_key,
          providerParticipantId: claim.provider_participant_id,
          participantKey: claim.participant_key,
          firstAttemptId: claim.first_attempt_id,
          lastAttemptId: claim.last_attempt_id,
        })),
    };
  }

  private room(): ProviderIdentityRoomRow | null {
    return (
      this.ctx.storage.sql
        .exec<ProviderIdentityRoomRow>(
          "SELECT * FROM provider_identity_room WHERE singleton = 1",
        )
        .toArray()[0] ?? null
    );
  }

  private claim(
    providerIdentityKey: string,
  ): ProviderIdentityClaimRow | null {
    return (
      this.ctx.storage.sql
        .exec<ProviderIdentityClaimRow>(
          `SELECT * FROM provider_identity_claims
           WHERE provider_identity_key = ?`,
          providerIdentityKey,
        )
        .toArray()[0] ?? null
    );
  }

  private claimByProviderParticipant(
    providerParticipantId: string,
  ): ProviderIdentityClaimRow | null {
    return (
      this.ctx.storage.sql
        .exec<ProviderIdentityClaimRow>(
          `SELECT * FROM provider_identity_claims
           WHERE provider_participant_id = ?`,
          providerParticipantId,
        )
        .toArray()[0] ?? null
    );
  }

  private claimCount(): number {
    return this.ctx.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM provider_identity_claims",
      )
      .one().count;
  }
}

export function providerIdentityShardIndex(
  providerIdentityKey: string,
): number {
  if (!PROVIDER_IDENTITY_KEY.test(providerIdentityKey)) {
    throw invalidShard();
  }
  const index = BASE64_URL.indexOf(providerIdentityKey[0]!);
  if (index < 0) throw invalidShard();
  return index;
}

export function providerIdentityShardName(
  roomId: string,
  shardIndex: number,
): string {
  if (
    !ROOM_ID.test(roomId) ||
    !Number.isInteger(shardIndex) ||
    shardIndex < 0 ||
    shardIndex >= PROVIDER_IDENTITY_SHARD_COUNT
  ) {
    throw invalidShard();
  }
  return `provider-identity:v1:${roomId}:${shardIndex}`;
}

function validClaim(input: ProviderIdentityClaimInput): boolean {
  return (
    OPAQUE_PROVIDER_ID.test(input.tenantId) &&
    UUID.test(input.sessionId) &&
    UUID.test(input.roomEpoch) &&
    ROOM_ID.test(input.roomId) &&
    OPAQUE_PROVIDER_ID.test(input.providerMeetingId) &&
    Number.isInteger(input.shardIndex) &&
    input.shardIndex >= 0 &&
    input.shardIndex < PROVIDER_IDENTITY_SHARD_COUNT &&
    PROVIDER_IDENTITY_KEY.test(input.providerIdentityKey) &&
    OPAQUE_PROVIDER_ID.test(input.providerParticipantId) &&
    PARTICIPANT_KEY.test(input.participantKey) &&
    PRINCIPAL_ID.test(input.principalId) &&
    UUID.test(input.attemptId) &&
    isCanonicalUtcInstant(input.now)
  );
}

function validQuotaPin(input: AdmissionQuotaPinInput): boolean {
  return (
    OPAQUE_PROVIDER_ID.test(input.tenantId) &&
    UUID.test(input.sessionId) &&
    UUID.test(input.roomEpoch) &&
    ROOM_ID.test(input.roomId) &&
    OPAQUE_PROVIDER_ID.test(input.providerMeetingId) &&
    Number.isSafeInteger(input.maxDailyAdmissionsPerRoom) &&
    input.maxDailyAdmissionsPerRoom >= 1 &&
    input.maxDailyAdmissionsPerRoom <= 100_000 &&
    isCanonicalUtcInstant(input.now)
  );
}

function matchesRoomIdentity(
  row: ProviderIdentityRoomRow,
  input: {
    tenantId: string;
    sessionId: string;
    roomEpoch: string;
    roomId: string;
    providerMeetingId: string;
    shardIndex: number;
  },
): boolean {
  return (
    row.tenant_id === input.tenantId &&
    row.senti_session_id === input.sessionId &&
    row.room_epoch === input.roomEpoch &&
    row.room_id === input.roomId &&
    row.provider_meeting_id === input.providerMeetingId &&
    row.shard_index === input.shardIndex
  );
}

function matchesClaim(
  row: ProviderIdentityClaimRow,
  input: ProviderIdentityClaimInput,
): boolean {
  return (
    row.provider_identity_key === input.providerIdentityKey &&
    row.provider_participant_id === input.providerParticipantId &&
    row.participant_key === input.participantKey
  );
}

function invalidShard(): HttpError {
  return new HttpError(
    503,
    "invalid_provider_identity_shard",
    "The provider identity shard is invalid.",
  );
}

import { env } from "cloudflare:workers";
import {
  evictDurableObject,
  reset,
  runInDurableObject,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { RoomRecord } from "../src/contracts";
import type { RuntimeEnv } from "../src/env";
import {
  ADMISSION_SHARD_COUNT,
  RoomAdmissionShard,
  admissionShardDailyLimit,
  admissionShardIndex,
  admissionShardName,
  type AdmissionFenceInput,
  type AdmissionLookupInput,
  type AdmissionReservationInput,
} from "../src/room-admission-shard";
import {
  deriveParticipantId,
  deriveProviderIdentityKey,
  deriveRoomId,
} from "../src/identity";
import {
  providerIdentityShardIndex,
  providerIdentityShardName,
} from "../src/room-provider-identity-shard";

const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const TENANT_ID = "tenant-demo";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const ROOM_SECRET = "room-key-test-secret-at-least-thirty-two-characters";
const IDENTITY_SECRET =
  "identity-test-secret-at-least-thirty-two-characters";
const NOW = "2026-07-29T12:00:00.000Z";
const PROVIDER_PARTICIPANT_ID =
  "e32fb785-ddd0-4b96-b577-879327c0082f";

describe("RoomAdmissionShard invariants", () => {
  let testEnv: RuntimeEnv;
  let roomId: string;
  let room: RoomRecord;
  let participantKey: string;
  let shardIndex: number;
  let shard: DurableObjectStub<RoomAdmissionShard>;

  beforeEach(async () => {
    await reset();
    testEnv = env as unknown as RuntimeEnv;
    roomId = await deriveRoomId(
      ROOM_SECRET,
      TENANT_ID,
      SESSION_ID,
      EPOCH,
    );
    room = {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      providerMeetingId: MEETING_ID,
      lifecycle: "ready",
      controlRevision: 0,
      transcriptMode: "post-meeting",
      createdAt: NOW,
      updatedAt: NOW,
    };
    participantKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      "human-carter",
    );
    shardIndex = admissionShardIndex(participantKey);
    shard = testEnv.ROOM_ADMISSION_SHARDS.getByName(
      admissionShardName(roomId, shardIndex),
    );
  });

  it("maps every HMAC alphabet prefix to exactly one of 64 shards", () => {
    const alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const observed = new Set<number>();
    for (const prefix of alphabet) {
      const key = `senti_${prefix}${"A".repeat(42)}`;
      const index = admissionShardIndex(key);
      expect(index).toBe(alphabet.indexOf(prefix));
      expect(admissionShardName(roomId, index)).toBe(
        `admission:v1:${roomId}:${index}`,
      );
      observed.add(index);
    }
    expect(observed.size).toBe(ADMISSION_SHARD_COUNT);
    expect(() => admissionShardIndex("provider-user-id")).toThrow();
    expect(() => admissionShardName(roomId, 64)).toThrow();
    expect(() => admissionShardDailyLimit(100_001, 0)).toThrow();
  });

  it("requires authoritative room priming and never rolls its revision floor back", async () => {
    expect(
      await shard.reserveAdmission(reservation()),
    ).toEqual({ disposition: "room_not_ready" });

    const initial = await shard.primeRoom({
      room: { ...room, controlRevision: 7 },
      shardIndex,
      now: NOW,
      maxDailyAdmissionsPerRoom: 100_000,
    });
    expect(initial).toMatchObject({
      disposition: "ready",
      room: {
        roomId,
        providerMeetingId: MEETING_ID,
        controlRevisionFloor: 7,
        maxDailyAdmissionsPerRoom: 100_000,
      },
    });
    const stale = await shard.primeRoom({
      room: { ...room, controlRevision: 2 },
      shardIndex,
      now: plusMs(1_000),
      maxDailyAdmissionsPerRoom: 100_000,
    });
    expect(stale).toMatchObject({
      disposition: "ready",
      room: { controlRevisionFloor: 7 },
    });
    const advanced = await shard.primeRoom({
      room: { ...room, controlRevision: 9 },
      shardIndex,
      now: plusMs(2_000),
      maxDailyAdmissionsPerRoom: 100_000,
    });
    expect(advanced).toMatchObject({
      disposition: "ready",
      room: { controlRevisionFloor: 9 },
    });
    expect(
      await shard.primeRoom({
        room: {
          ...room,
          providerMeetingId: "provider-meeting-replacement",
        },
        shardIndex,
        now: plusMs(3_000),
        maxDailyAdmissionsPerRoom: 100_000,
      }),
    ).toEqual({ disposition: "identity_mismatch" });
  });

  it("fences create completion and exposes only a server-owned active binding", async () => {
    await prime();
    const reserved = await shard.reserveAdmission(reservation());
    if (reserved.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    expect(reserved.providerParticipantId).toBeNull();
    expect(reserved.fence).toMatch(
      /^[0-9a-f]{8}-[0-9a-f-]{27}$/i,
    );
    expect(reserved.attemptId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f-]{27}$/i,
    );

    expect(
      await shard.completeAdmission({
        ...fenceInput(reserved.fence, plusMs(1_000)),
        providerParticipantId: "provider-other",
        fence: crypto.randomUUID(),
      }),
    ).toEqual({ disposition: "invalid_fence" });

    const completed = await shard.completeAdmission({
      ...fenceInput(reserved.fence, plusMs(2_000)),
      providerParticipantId: PROVIDER_PARTICIPANT_ID,
    });
    expect(completed).toMatchObject({
      disposition: "applied",
      admission: {
        participantKey,
        principalId: "human-carter",
        admissionRevision: 1,
        membershipRole: "owner",
        role: "moderator",
        displayName: "Carter",
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      },
    });

    if (completed.disposition !== "applied") {
      throw new Error("Expected applied admission.");
    }
    const lookup = await shard.lookupActive(lookupInput());
    expect(lookup).toEqual({
      disposition: "active",
      room: {
        tenantId: TENANT_ID,
        sessionId: SESSION_ID,
        roomEpoch: EPOCH,
        roomId,
        shardIndex,
        providerMeetingId: MEETING_ID,
        lifecycle: "ready",
        controlRevisionFloor: 0,
        maxDailyAdmissionsPerRoom: 100_000,
        transcriptMode: "post-meeting",
      },
      admission: completed.admission,
    });
    const serialized = JSON.stringify(await shard.debugSnapshot());
    expect(serialized).not.toContain("authToken");
    expect(serialized).not.toContain("bearer");
    expect(serialized).not.toContain(IDENTITY_SECRET);
  });

  it("refreshes or updates one stable provider identity and restores known failures", async () => {
    await prime();
    await createActive();

    const refresh = await shard.reserveAdmission(
      reservation({ now: plusMs(2_000) }),
    );
    if (refresh.disposition !== "refresh") {
      throw new Error("Expected refresh reservation.");
    }
    expect(refresh.providerParticipantId).toBe(
      PROVIDER_PARTICIPANT_ID,
    );
    expect(
      await shard.releaseKnownFailure(
        fenceInput(refresh.fence, plusMs(3_000)),
      ),
    ).toEqual({ disposition: "released" });
    expect(await shard.lookupActive(lookupInput())).toMatchObject({
      disposition: "active",
      admission: {
        admissionRevision: 2,
        role: "moderator",
        displayName: "Carter",
      },
    });

    const update = await shard.reserveAdmission(
      reservation({
        membershipRole: "contributor",
        desiredRole: "speaker",
        displayName: "Carter Updated",
        now: plusMs(4_000),
      }),
    );
    if (update.disposition !== "update") {
      throw new Error("Expected update reservation.");
    }
    expect(
      await shard.completeAdmission({
        ...fenceInput(update.fence, plusMs(5_000)),
        providerParticipantId: "provider-replacement",
      }),
    ).toEqual({ disposition: "provider_identity_conflict" });
    expect(
      await shard.completeAdmission({
        ...fenceInput(update.fence, plusMs(6_000)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
    ).toMatchObject({
      disposition: "applied",
      admission: {
        admissionRevision: 3,
        membershipRole: "contributor",
        role: "speaker",
        displayName: "Carter Updated",
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      },
    });
  });

  it("turns an expired lease into reconciliation instead of issuing a second create", async () => {
    await prime();
    const first = await shard.reserveAdmission(reservation());
    if (first.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    expect(
      await shard.reserveAdmission(
        reservation({ now: plusMs(14_999) }),
      ),
    ).toEqual({ disposition: "busy" });

    const expired = await shard.reserveAdmission(
      reservation({ now: plusMs(15_001) }),
    );
    expect(expired).toMatchObject({
      disposition: "reconciliation_required",
      attemptId: first.attemptId,
    });
    expect(
      await shard.reserveAdmission(
        reservation({ now: plusMs(30_000) }),
      ),
    ).toMatchObject({
      disposition: "reconciliation_required",
      attemptId: first.attemptId,
    });
    expect(
      await shard.releaseKnownFailure(
        fenceInput(first.fence, plusMs(30_001)),
      ),
    ).toEqual({ disposition: "invalid_fence" });

    expect(
      await shard.completeAdmission({
        ...fenceInput(first.fence, plusMs(30_002)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
    ).toMatchObject({
      disposition: "applied",
      admission: { providerParticipantId: PROVIDER_PARTICIPANT_ID },
    });
  });

  it("makes an explicitly uncertain result sticky until exact reconciliation", async () => {
    await prime();
    const first = await shard.reserveAdmission(reservation());
    if (first.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    expect(
      await shard.markOutcomeUncertain(
        fenceInput(first.fence, plusMs(1_000)),
      ),
    ).toEqual({
      disposition: "reconciliation_required",
      attemptId: first.attemptId,
    });
    expect(
      await shard.markOutcomeUncertain(
        fenceInput(first.fence, plusMs(2_000)),
      ),
    ).toEqual({
      disposition: "reconciliation_required",
      attemptId: first.attemptId,
    });
    expect(
      await shard.releaseKnownFailure(
        fenceInput(first.fence, plusMs(3_000)),
      ),
    ).toEqual({ disposition: "invalid_fence" });
    expect(
      await shard.reserveAdmission(
        reservation({ now: plusMs(60_000) }),
      ),
    ).toMatchObject({
      disposition: "reconciliation_required",
      attemptId: first.attemptId,
    });
    expect(
      await shard.resolveReconciledAbsent(
        fenceInput(first.fence, plusMs(60_001)),
      ),
    ).toEqual({ disposition: "released" });
    const replacement = await shard.reserveAdmission(
      reservation({ now: plusMs(60_002) }),
    );
    expect(replacement).toMatchObject({ disposition: "create" });
    if (replacement.disposition === "create") {
      expect(replacement.attemptId).not.toBe(first.attemptId);
    }
  });

  it("rejects principal and provider identity aliasing inside one shard", async () => {
    await prime();
    await createActive();
    const secondIdentity = await findParticipantIdentity(
      roomId,
      (candidate) =>
        candidate.participantKey !== participantKey &&
        admissionShardIndex(candidate.participantKey) === shardIndex,
    );
    const secondKey = secondIdentity.participantKey;

    expect(
      await shard.reserveAdmission(
        reservation({
          participantKey: secondKey,
          principalId: "human-carter",
          now: plusMs(2_000),
        }),
      ),
    ).toEqual({ disposition: "invalid" });

    const second = await shard.reserveAdmission(
      reservation({
        participantKey: secondKey,
        principalId: secondIdentity.principalId,
        displayName: "Other",
        now: plusMs(3_000),
      }),
    );
    if (second.disposition !== "create") {
      throw new Error("Expected second create reservation.");
    }
    expect(
      await shard.completeAdmission({
        ...fenceInput(
          second.fence,
          plusMs(4_000),
          secondKey,
        ),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
    ).toEqual({ disposition: "provider_identity_conflict" });
  });

  it("partitions the room admission budget exactly and never grows past a shard limit", async () => {
    const maximum = 10_003;
    const limits = Array.from(
      { length: ADMISSION_SHARD_COUNT },
      (_, index) => admissionShardDailyLimit(maximum, index),
    );
    expect(limits.reduce((sum, value) => sum + value, 0)).toBe(
      maximum,
    );
    expect(Math.max(...limits) - Math.min(...limits)).toBeLessThanOrEqual(
      1,
    );

    const exactRoomMaximum = ADMISSION_SHARD_COUNT;
    await prime(exactRoomMaximum);
    const first = await shard.reserveAdmission(
      reservation(),
    );
    if (first.disposition !== "create") {
      throw new Error("Expected budgeted reservation.");
    }
    await shard.releaseKnownFailure(
      fenceInput(first.fence, plusMs(1_000)),
    );
    expect(
      await shard.primeRoom({
        room,
        shardIndex,
        now: plusMs(2_000),
        maxDailyAdmissionsPerRoom: 2 * ADMISSION_SHARD_COUNT,
      }),
    ).toEqual({ disposition: "quota_mismatch" });
    expect(
      await shard.reserveAdmission(
        reservation({ now: plusMs(3_000) }),
      ),
    ).toEqual({ disposition: "over_budget" });
    expect((await shard.debugSnapshot()).dailyUsage).toEqual([
      { day: "2026-07-29", requests: 1 },
    ]);
  });

  it("pins one quota authority across shards and rejects a concurrent reconfiguration", async () => {
    const other = await findParticipantIdentity(
      roomId,
      (candidate) =>
        admissionShardIndex(candidate.participantKey) !== shardIndex,
    );
    const otherShardIndex = admissionShardIndex(
      other.participantKey,
    );
    const otherShard = testEnv.ROOM_ADMISSION_SHARDS.getByName(
      admissionShardName(roomId, otherShardIndex),
    );
    const results = await Promise.all([
      shard.primeRoom({
        room,
        shardIndex,
        now: NOW,
        maxDailyAdmissionsPerRoom: 64,
      }),
      otherShard.primeRoom({
        room,
        shardIndex: otherShardIndex,
        now: NOW,
        maxDailyAdmissionsPerRoom: 65,
      }),
    ]);
    expect(
      results.map((result) => result.disposition).sort(),
    ).toEqual(["quota_mismatch", "ready"]);

    const winningMaximum =
      results[0]!.disposition === "ready" ? 64 : 65;
    expect(
      await shard.primeRoom({
        room,
        shardIndex,
        now: plusMs(1_000),
        maxDailyAdmissionsPerRoom: winningMaximum,
      }),
    ).toMatchObject({ disposition: "ready" });
    expect(
      await otherShard.primeRoom({
        room,
        shardIndex: otherShardIndex,
        now: plusMs(1_000),
        maxDailyAdmissionsPerRoom: winningMaximum,
      }),
    ).toMatchObject({ disposition: "ready" });
  });

  it("fails legacy admission rows closed when no historical quota was pinned", async () => {
    await runInDurableObject(
      shard,
      async (_instance, state) => {
        state.storage.sql.exec(
          `DROP TABLE admissions;
           DROP TABLE admission_room;
           CREATE TABLE admission_room (
             singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
             tenant_id TEXT NOT NULL,
             senti_session_id TEXT NOT NULL,
             room_epoch TEXT NOT NULL,
             room_id TEXT NOT NULL,
             shard_index INTEGER NOT NULL,
             provider_meeting_id TEXT NOT NULL,
             lifecycle TEXT NOT NULL,
             control_revision_floor INTEGER NOT NULL,
             transcript_mode TEXT NOT NULL,
             created_at TEXT NOT NULL,
             updated_at TEXT NOT NULL,
             CHECK (control_revision_floor >= 0),
             CHECK (shard_index >= 0 AND shard_index < 64),
             CHECK (lifecycle IN ('ready', 'ended')),
             CHECK (transcript_mode = 'post-meeting')
           );
           CREATE TABLE admissions (
             participant_key TEXT PRIMARY KEY,
             principal_id TEXT NOT NULL UNIQUE,
             membership_role TEXT NOT NULL,
             role TEXT,
             pending_role TEXT,
             display_name TEXT,
             pending_display_name TEXT,
             provider_participant_id TEXT,
             revision INTEGER NOT NULL,
             state TEXT NOT NULL,
             fence TEXT,
             attempt_id TEXT,
             lease_until INTEGER,
             created_at TEXT NOT NULL,
             updated_at TEXT NOT NULL
           );
           INSERT INTO admission_room (
             singleton, tenant_id, senti_session_id, room_epoch, room_id,
             shard_index, provider_meeting_id, lifecycle,
             control_revision_floor, transcript_mode, created_at, updated_at
           ) VALUES (1, ?, ?, ?, ?, ?, ?, 'ready', 0, 'post-meeting', ?, ?)`,
          TENANT_ID,
          SESSION_ID,
          EPOCH,
          roomId,
          shardIndex,
          MEETING_ID,
          NOW,
          NOW,
        );
      },
    );
    await evictDurableObject(shard);
    const migratedColumns = await runInDurableObject(
      shard,
      async (_instance, state) => ({
        room: state.storage.sql
          .exec<{ name: string }>("PRAGMA table_info(admission_room)")
          .toArray()
          .map((column) => column.name),
        admissions: state.storage.sql
          .exec<{ name: string }>("PRAGMA table_info(admissions)")
          .toArray()
          .map((column) => column.name),
      }),
    );
    expect(migratedColumns.room).toContain(
      "max_daily_admissions_per_room",
    );
    expect(migratedColumns.admissions).toEqual(
      expect.arrayContaining([
        "pending_provider_participant_id",
        "completed_fence",
        "completed_attempt_id",
      ]),
    );
    expect(
      await shard.primeRoom({
        room,
        shardIndex,
        now: plusMs(1_000),
        maxDailyAdmissionsPerRoom: 64,
      }),
    ).toEqual({ disposition: "quota_mismatch" });
    expect(
      await shard.reserveAdmission(reservation()),
    ).toEqual({ disposition: "room_not_ready" });
  });

  it("uses exact UTC days and rejects every noncanonical timestamp form", async () => {
    await prime(ADMISSION_SHARD_COUNT);
    for (const malformed of [
      "2026-07-29T08:00:00.000-04:00",
      "Wed, 29 Jul 2026 12:00:00 GMT",
      "2026-02-30T12:00:00.000Z",
      "2026-07-29T12:00:00Z",
      "2026-07-29T12:00:00.000+00:00",
      "2026-7-29T12:00:00.000Z",
    ]) {
      expect(
        await shard.reserveAdmission(
          reservation({ now: malformed }),
        ),
      ).toEqual({ disposition: "invalid" });
    }
    expect((await shard.debugSnapshot()).dailyUsage).toEqual([]);

    const first = await shard.reserveAdmission(reservation());
    if (first.disposition !== "create") {
      throw new Error("Expected first UTC-day reservation.");
    }
    expect(
      await shard.releaseKnownFailure(
        fenceInput(first.fence, plusMs(1_000)),
      ),
    ).toEqual({ disposition: "released" });
    expect(
      await shard.reserveAdmission(
        reservation({ now: "2026-07-29T23:59:59.999Z" }),
      ),
    ).toEqual({ disposition: "over_budget" });
    expect(
      await shard.reserveAdmission(
        reservation({ now: "2026-07-30T00:00:00.000Z" }),
      ),
    ).toMatchObject({ disposition: "create" });
    expect((await shard.debugSnapshot()).dailyUsage).toEqual([
      { day: "2026-07-29", requests: 1 },
      { day: "2026-07-30", requests: 1 },
    ]);
  });

  it("assigns zero share below 64 without borrowing from another shard", async () => {
    const admittedIdentity = await findParticipantIdentity(
      roomId,
      (candidate) =>
        admissionShardIndex(candidate.participantKey) === 0,
    );
    const zeroShareIdentity = await findParticipantIdentity(
      roomId,
      (candidate) =>
        admissionShardIndex(candidate.participantKey) !== 0,
    );
    const admittedShard = await primeParticipant(
      admittedIdentity,
      1,
    );
    const zeroShareShard = await primeParticipant(
      zeroShareIdentity,
      1,
    );
    expect(
      await zeroShareShard.reserveAdmission(
        reservationFor(zeroShareIdentity),
      ),
    ).toEqual({ disposition: "over_budget" });
    expect(
      await admittedShard.reserveAdmission(
        reservationFor(admittedIdentity),
      ),
    ).toMatchObject({ disposition: "create" });
  });

  it("serializes one exact quota boundary under concurrent reservations", async () => {
    await prime(ADMISSION_SHARD_COUNT);
    const other = await findParticipantIdentity(
      roomId,
      (candidate) =>
        candidate.participantKey !== participantKey &&
        admissionShardIndex(candidate.participantKey) === shardIndex,
    );
    const results = await Promise.all([
      shard.reserveAdmission(reservation()),
      shard.reserveAdmission(reservationFor(other)),
    ]);
    expect(
      results.map((result) => result.disposition).sort(),
    ).toEqual(["create", "over_budget"]);
    expect((await shard.debugSnapshot()).dailyUsage).toEqual([
      { day: "2026-07-29", requests: 1 },
    ]);
  });

  it("rejects a correct payload sent to the wrong physical admission object", async () => {
    const wrongShard = testEnv.ROOM_ADMISSION_SHARDS.getByName(
      admissionShardName(
        roomId,
        (shardIndex + 1) % ADMISSION_SHARD_COUNT,
      ),
    );
    expect(
      await wrongShard.primeRoom({
        room,
        shardIndex,
        now: NOW,
        maxDailyAdmissionsPerRoom: 100_000,
      }),
    ).toEqual({ disposition: "invalid" });
    expect(
      await wrongShard.reserveAdmission(reservation()),
    ).toEqual({ disposition: "invalid" });
    expect((await wrongShard.debugSnapshot()).room).toBeNull();
  });

  it("rejects one principal routed under another shard's participant key", async () => {
    await prime();
    const other = await findParticipantIdentity(
      roomId,
      (candidate) =>
        admissionShardIndex(candidate.participantKey) !== shardIndex,
    );
    const otherShard = await primeParticipant(other);
    expect(
      await otherShard.reserveAdmission(
        reservationFor({
          ...other,
          principalId: "human-carter",
        }),
      ),
    ).toEqual({ disposition: "invalid" });
    expect((await otherShard.debugSnapshot()).dailyUsage).toEqual([]);
  });

  it("admits one room-wide provider identity across concurrent admission shards", async () => {
    await prime();
    const other = await findParticipantIdentity(
      roomId,
      (candidate) =>
        admissionShardIndex(candidate.participantKey) !== shardIndex,
    );
    const otherShard = await primeParticipant(other);
    const first = await shard.reserveAdmission(reservation());
    const second = await otherShard.reserveAdmission(
      reservationFor(other),
    );
    if (
      first.disposition !== "create" ||
      second.disposition !== "create"
    ) {
      throw new Error("Expected two cross-shard reservations.");
    }
    const results = await Promise.all([
      shard.completeAdmission({
        ...fenceInput(first.fence, plusMs(1_000)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
      otherShard.completeAdmission({
        ...fenceFor(other, second.fence, plusMs(1_000)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
    ]);
    expect(
      results.map((result) => result.disposition).sort(),
    ).toEqual(["applied", "provider_identity_conflict"]);
    const losingShard =
      results[0]!.disposition === "provider_identity_conflict"
        ? shard
        : otherShard;
    const losingFence =
      results[0]!.disposition === "provider_identity_conflict"
        ? fenceInput(first.fence, plusMs(2_000))
        : fenceFor(other, second.fence, plusMs(2_000));
    expect(
      await losingShard.releaseKnownFailure(losingFence),
    ).toMatchObject({ disposition: "reconciliation_required" });
    expect(
      await losingShard.resolveReconciledAbsent({
        ...losingFence,
        now: plusMs(3_000),
      }),
    ).toMatchObject({ disposition: "reconciliation_required" });
  });

  it("pins one provider completion intent before any owner RPC await", async () => {
    await prime();
    const reserved = await shard.reserveAdmission(reservation());
    if (reserved.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    const alternateProvider = "provider-alternate";
    const results = await Promise.all([
      shard.completeAdmission({
        ...fenceInput(reserved.fence, plusMs(1_000)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
      shard.completeAdmission({
        ...fenceInput(reserved.fence, plusMs(1_001)),
        providerParticipantId: alternateProvider,
      }),
    ]);
    expect(
      results.map((result) => result.disposition).sort(),
    ).toEqual(["applied", "provider_identity_conflict"]);

    const providerIds = [
      PROVIDER_PARTICIPANT_ID,
      alternateProvider,
    ];
    const ownerNames = new Set<string>();
    for (const providerId of providerIds) {
      const key = await deriveProviderIdentityKey(roomId, providerId);
      ownerNames.add(
        providerIdentityShardName(
          roomId,
          providerIdentityShardIndex(key),
        ),
      );
    }
    let claims = 0;
    for (const name of ownerNames) {
      claims += (
        await testEnv.ROOM_PROVIDER_IDENTITY_SHARDS
          .getByName(name)
          .debugSnapshot()
      ).claims.length;
    }
    expect(claims).toBe(1);
  });

  it("recovers after an owner claim commits before the local completion", async () => {
    await prime();
    const reserved = await shard.reserveAdmission(reservation());
    if (reserved.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    await runInDurableObject(
      shard,
      async (_instance, state) => {
        state.storage.sql.exec(
          `UPDATE admissions
           SET pending_provider_participant_id = ?, updated_at = ?
           WHERE participant_key = ? AND fence = ?`,
          PROVIDER_PARTICIPANT_ID,
          plusMs(1_000),
          participantKey,
          reserved.fence,
        );
      },
    );
    const providerKey = await deriveProviderIdentityKey(
      roomId,
      PROVIDER_PARTICIPANT_ID,
    );
    const ownerIndex = providerIdentityShardIndex(providerKey);
    const owner =
      testEnv.ROOM_PROVIDER_IDENTITY_SHARDS.getByName(
        providerIdentityShardName(roomId, ownerIndex),
      );
    expect(
      await owner.claimProviderIdentity({
        tenantId: TENANT_ID,
        sessionId: SESSION_ID,
        roomEpoch: EPOCH,
        roomId,
        providerMeetingId: MEETING_ID,
        shardIndex: ownerIndex,
        providerIdentityKey: providerKey,
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
        participantKey,
        principalId: "human-carter",
        attemptId: reserved.attemptId,
        now: plusMs(1_000),
      }),
    ).toMatchObject({ disposition: "claimed" });
    await Promise.all([
      evictDurableObject(shard),
      evictDurableObject(owner),
    ]);
    expect(
      await shard.completeAdmission({
        ...fenceInput(reserved.fence, plusMs(2_000)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
    ).toMatchObject({
      disposition: "applied",
      admission: { participantKey, providerParticipantId: PROVIDER_PARTICIPANT_ID },
    });
    expect((await owner.debugSnapshot()).claims).toHaveLength(1);
  });

  it("persists an applied completion receipt across both object evictions", async () => {
    await prime();
    const reserved = await shard.reserveAdmission(reservation());
    if (reserved.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    const completion = {
      ...fenceInput(reserved.fence, plusMs(1_000)),
      providerParticipantId: PROVIDER_PARTICIPANT_ID,
    };
    const first = await shard.completeAdmission(completion);
    expect(first).toMatchObject({ disposition: "applied" });

    const providerKey = await deriveProviderIdentityKey(
      roomId,
      PROVIDER_PARTICIPANT_ID,
    );
    const owner =
      testEnv.ROOM_PROVIDER_IDENTITY_SHARDS.getByName(
        providerIdentityShardName(
          roomId,
          providerIdentityShardIndex(providerKey),
        ),
      );
    await Promise.all([
      evictDurableObject(shard),
      evictDurableObject(owner),
    ]);
    expect(await shard.completeAdmission(completion)).toEqual(first);
  });

  it("linearizes completion against release and room end", async () => {
    await prime();
    const releasedReservation =
      await shard.reserveAdmission(reservation());
    if (releasedReservation.disposition !== "create") {
      throw new Error("Expected release-race reservation.");
    }
    const [completion, release] = await Promise.all([
      shard.completeAdmission({
        ...fenceInput(
          releasedReservation.fence,
          plusMs(1_000),
        ),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
      shard.releaseKnownFailure(
        fenceInput(releasedReservation.fence, plusMs(1_001)),
      ),
    ]);
    if (release.disposition === "released") {
      expect(completion.disposition).toBe("invalid_fence");
    } else {
      expect(completion.disposition).toBe("applied");
      expect([
        "invalid_fence",
        "reconciliation_required",
      ]).toContain(release.disposition);
    }

    await reset();
    testEnv = env as unknown as RuntimeEnv;
    shard = testEnv.ROOM_ADMISSION_SHARDS.getByName(
      admissionShardName(roomId, shardIndex),
    );
    await prime();
    const endedReservation =
      await shard.reserveAdmission(reservation());
    if (endedReservation.disposition !== "create") {
      throw new Error("Expected end-race reservation.");
    }
    const [endedCompletion, ended] = await Promise.all([
      shard.completeAdmission({
        ...fenceInput(
          endedReservation.fence,
          plusMs(1_000),
        ),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
      shard.endRoom({
        room: {
          ...room,
          lifecycle: "ended",
          controlRevision: 1,
          updatedAt: plusMs(1_001),
        },
        shardIndex,
        now: plusMs(1_001),
      }),
    ]);
    expect(ended.disposition).toBe("ended");
    expect(["applied", "room_not_ready"]).toContain(
      endedCompletion.disposition,
    );
  });

  it("restores an existing active binding after exact absent reconciliation", async () => {
    await prime();
    await createActive();
    const refresh = await shard.reserveAdmission(
      reservation({ now: plusMs(2_000) }),
    );
    if (refresh.disposition !== "refresh") {
      throw new Error("Expected refresh reservation.");
    }
    expect(
      await shard.markOutcomeUncertain(
        fenceInput(refresh.fence, plusMs(3_000)),
      ),
    ).toMatchObject({ disposition: "reconciliation_required" });
    expect(
      await shard.resolveReconciledAbsent(
        fenceInput(refresh.fence, plusMs(4_000)),
      ),
    ).toEqual({ disposition: "released" });
    expect(await shard.lookupActive(lookupInput())).toMatchObject({
      disposition: "active",
      admission: {
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
        role: "moderator",
        displayName: "Carter",
      },
    });
  });

  it("rejects new participants at the hard shard capacity before consuming quota", async () => {
    await prime();
    await runInDurableObject(
      shard,
      async (_instance, state) => {
        for (let index = 0; index < 4_096; index += 1) {
          state.storage.sql.exec(
            `INSERT INTO admissions (
               participant_key, principal_id, membership_role, role,
               pending_role, display_name, pending_display_name,
               provider_participant_id, revision, state, fence,
               attempt_id, lease_until, created_at, updated_at
             ) VALUES (
               ?, ?, 'viewer', 'listener', NULL, 'Capacity row', NULL,
               ?, 1, 'active', NULL, NULL, NULL, ?, ?
             )`,
            `seed-participant-${index}`,
            `seed-principal-${index}`,
            `seed-provider-${index}`,
            NOW,
            NOW,
          );
        }
      },
    );
    expect(
      await shard.reserveAdmission(reservation()),
    ).toEqual({ disposition: "capacity" });
    const usageCount = await runInDurableObject(
      shard,
      async (_instance, state) =>
        state.storage.sql
          .exec<{ count: number }>(
            "SELECT COUNT(*) AS count FROM admission_daily_usage",
          )
          .one().count,
    );
    expect(usageCount).toBe(0);
  });

  it("fails closed on wrong room, shard, principal, fence, and malformed time", async () => {
    await prime();
    expect(
      await shard.reserveAdmission(
        reservation({ tenantId: "tenant-other" }),
      ),
    ).toEqual({ disposition: "identity_mismatch" });
    expect(
      await shard.reserveAdmission(
        reservation({
          shardIndex: (shardIndex + 1) % ADMISSION_SHARD_COUNT,
        }),
      ),
    ).toEqual({ disposition: "invalid" });
    expect(
      await shard.reserveAdmission(
        reservation({ now: "not-a-time" }),
      ),
    ).toEqual({ disposition: "invalid" });

    const first = await shard.reserveAdmission(reservation());
    if (first.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    expect(
      await shard.lookupActive(
        lookupInput({ principalId: "human-other" }),
      ),
    ).toEqual({ disposition: "not_found" });
    expect(
      await shard.markOutcomeUncertain({
        ...fenceInput(first.fence, plusMs(1_000)),
        fence: crypto.randomUUID(),
      }),
    ).toEqual({ disposition: "invalid_fence" });
  });

  it("irreversibly fences new admission work after the room epoch ends", async () => {
    await prime();
    const first = await shard.reserveAdmission(reservation());
    if (first.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    const ended = await shard.endRoom({
      room: {
        ...room,
        lifecycle: "ended",
        controlRevision: 5,
        updatedAt: plusMs(2_000),
      },
      shardIndex,
      now: plusMs(2_000),
    });
    expect(ended).toMatchObject({
      disposition: "ended",
      room: {
        lifecycle: "ended",
        controlRevisionFloor: 5,
        maxDailyAdmissionsPerRoom: 100_000,
      },
    });
    expect(
      await shard.primeRoom({
        room,
        shardIndex,
        now: plusMs(3_000),
        maxDailyAdmissionsPerRoom: 100_000,
      }),
    ).toEqual({ disposition: "room_ended" });
    expect(
      await shard.reserveAdmission(
        reservation({ now: plusMs(4_000) }),
      ),
    ).toEqual({ disposition: "room_not_ready" });
    expect(
      await shard.completeAdmission({
        ...fenceInput(first.fence, plusMs(5_000)),
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
      }),
    ).toEqual({ disposition: "room_not_ready" });
    expect(
      await shard.releaseKnownFailure(
        fenceInput(first.fence, plusMs(6_000)),
      ),
    ).toEqual({ disposition: "released" });
  });

  async function prime(
    maxDailyAdmissionsPerRoom = 100_000,
  ): Promise<void> {
    const result = await shard.primeRoom({
      room,
      shardIndex,
      now: NOW,
      maxDailyAdmissionsPerRoom,
    });
    if (result.disposition !== "ready") {
      throw new Error("Failed to prime admission room.");
    }
  }

  async function primeParticipant(
    identity: {
      principalId: string;
      participantKey: string;
    },
    maxDailyAdmissionsPerRoom = 100_000,
  ): Promise<DurableObjectStub<RoomAdmissionShard>> {
    const identityShardIndex = admissionShardIndex(
      identity.participantKey,
    );
    const identityShard = testEnv.ROOM_ADMISSION_SHARDS.getByName(
      admissionShardName(roomId, identityShardIndex),
    );
    const result = await identityShard.primeRoom({
      room,
      shardIndex: identityShardIndex,
      now: NOW,
      maxDailyAdmissionsPerRoom,
    });
    if (result.disposition !== "ready") {
      throw new Error("Failed to prime participant admission shard.");
    }
    return identityShard;
  }

  async function createActive(): Promise<void> {
    const reserved = await shard.reserveAdmission(reservation());
    if (reserved.disposition !== "create") {
      throw new Error("Expected create reservation.");
    }
    const completed = await shard.completeAdmission({
      ...fenceInput(reserved.fence, plusMs(1_000)),
      providerParticipantId: PROVIDER_PARTICIPANT_ID,
    });
    if (completed.disposition !== "applied") {
      throw new Error("Failed to complete admission.");
    }
  }

  function reservation(
    overrides: Partial<AdmissionReservationInput> = {},
  ): AdmissionReservationInput {
    return {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      shardIndex,
      participantKey,
      principalId: "human-carter",
      membershipRole: "owner",
      desiredRole: "moderator",
      displayName: "Carter",
      now: NOW,
      ...overrides,
    };
  }

  function reservationFor(identity: {
    principalId: string;
    participantKey: string;
  }): AdmissionReservationInput {
    return reservation({
      shardIndex: admissionShardIndex(identity.participantKey),
      participantKey: identity.participantKey,
      principalId: identity.principalId,
      membershipRole: "viewer",
      desiredRole: "listener",
      displayName: identity.principalId,
    });
  }

  function fenceInput(
    fence: string,
    now: string,
    key = participantKey,
  ): AdmissionFenceInput {
    return {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      shardIndex,
      participantKey: key,
      fence,
      now,
    };
  }

  function fenceFor(
    identity: { participantKey: string },
    fence: string,
    now: string,
  ): AdmissionFenceInput {
    return {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      shardIndex: admissionShardIndex(identity.participantKey),
      participantKey: identity.participantKey,
      fence,
      now,
    };
  }

  function lookupInput(
    overrides: Partial<AdmissionLookupInput> = {},
  ): AdmissionLookupInput {
    return {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      shardIndex,
      participantKey,
      principalId: "human-carter",
      ...overrides,
    };
  }
});

function plusMs(milliseconds: number): string {
  return new Date(Date.parse(NOW) + milliseconds).toISOString();
}

async function findParticipantIdentity(
  roomId: string,
  predicate: (candidate: {
    principalId: string;
    participantKey: string;
  }) => boolean,
): Promise<{ principalId: string; participantKey: string }> {
  for (let index = 0; index < 10_000; index += 1) {
    const principalId = `human-test-${index}`;
    const participantKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      principalId,
    );
    const candidate = { principalId, participantKey };
    if (predicate(candidate)) return candidate;
  }
  throw new Error("Unable to derive a matching participant identity.");
}

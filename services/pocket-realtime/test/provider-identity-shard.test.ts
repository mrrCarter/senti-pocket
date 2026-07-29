import { env } from "cloudflare:workers";
import {
  evictDurableObject,
  reset,
  runInDurableObject,
} from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import type { RuntimeEnv } from "../src/env";
import {
  deriveParticipantId,
  deriveProviderIdentityKey,
  deriveRoomId,
} from "../src/identity";
import {
  MAX_PROVIDER_IDENTITIES_PER_SHARD,
  providerIdentityShardIndex,
  providerIdentityShardName,
  type ProviderIdentityClaimInput,
  type RoomProviderIdentityShard,
} from "../src/room-provider-identity-shard";

const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const TENANT_ID = "tenant-demo";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const ROOM_SECRET =
  "room-key-test-secret-at-least-thirty-two-characters";
const IDENTITY_SECRET =
  "identity-test-secret-at-least-thirty-two-characters";
const NOW = "2026-07-29T12:00:00.000Z";
const PROVIDER_PARTICIPANT_ID =
  "e32fb785-ddd0-4b96-b577-879327c0082f";

describe("RoomProviderIdentityShard invariants", () => {
  let testEnv: RuntimeEnv;
  let roomId: string;
  let participantKey: string;
  let providerIdentityKey: string;
  let shardIndex: number;
  let shard: DurableObjectStub<RoomProviderIdentityShard>;

  beforeEach(async () => {
    await reset();
    testEnv = env as unknown as RuntimeEnv;
    roomId = await deriveRoomId(
      ROOM_SECRET,
      TENANT_ID,
      SESSION_ID,
      EPOCH,
    );
    participantKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      "human-carter",
    );
    providerIdentityKey = await deriveProviderIdentityKey(
      roomId,
      PROVIDER_PARTICIPANT_ID,
    );
    shardIndex = providerIdentityShardIndex(providerIdentityKey);
    shard = testEnv.ROOM_PROVIDER_IDENTITY_SHARDS.getByName(
      providerIdentityShardName(roomId, shardIndex),
    );
  });

  it("pins one room-wide quota on the exact physical authority", async () => {
    const authority =
      testEnv.ROOM_PROVIDER_IDENTITY_SHARDS.getByName(
        providerIdentityShardName(roomId, 0),
      );
    const input = {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      providerMeetingId: MEETING_ID,
      maxDailyAdmissionsPerRoom: 10_003,
      now: NOW,
    };
    expect(await authority.pinAdmissionQuota(input)).toEqual({
      disposition: "ready",
    });
    expect(
      await authority.pinAdmissionQuota({
        ...input,
        now: plusMs(1_000),
      }),
    ).toEqual({ disposition: "ready" });
    expect(
      await authority.pinAdmissionQuota({
        ...input,
        maxDailyAdmissionsPerRoom: 10_004,
        now: plusMs(2_000),
      }),
    ).toEqual({ disposition: "quota_mismatch" });

    const wrongAuthority =
      testEnv.ROOM_PROVIDER_IDENTITY_SHARDS.getByName(
        providerIdentityShardName(roomId, 1),
      );
    expect(
      await wrongAuthority.pinAdmissionQuota(input),
    ).toEqual({ disposition: "invalid" });
  });

  it("claims once, replays after eviction, and never stores raw principals", async () => {
    const firstAttempt = crypto.randomUUID();
    expect(
      await shard.claimProviderIdentity(
        claimInput({ attemptId: firstAttempt }),
      ),
    ).toEqual({ disposition: "claimed" });

    await evictDurableObject(shard);
    const secondAttempt = crypto.randomUUID();
    expect(
      await shard.claimProviderIdentity(
        claimInput({
          attemptId: secondAttempt,
          now: plusMs(1_000),
        }),
      ),
    ).toEqual({ disposition: "replay" });

    const snapshot = await shard.debugSnapshot();
    expect(snapshot.claims).toEqual([
      {
        providerIdentityKey,
        providerParticipantId: PROVIDER_PARTICIPANT_ID,
        participantKey,
        firstAttemptId: firstAttempt,
        lastAttemptId: secondAttempt,
      },
    ]);
    expect(JSON.stringify(snapshot)).not.toContain("human-carter");
  });

  it("rejects wrong physical routing and direct principal-key poisoning", async () => {
    const wrongShard =
      testEnv.ROOM_PROVIDER_IDENTITY_SHARDS.getByName(
        providerIdentityShardName(
          roomId,
          (shardIndex + 1) % 64,
        ),
      );
    expect(
      await wrongShard.claimProviderIdentity(claimInput()),
    ).toEqual({ disposition: "invalid" });
    expect((await wrongShard.debugSnapshot()).claims).toEqual([]);

    expect(
      await shard.claimProviderIdentity(
        claimInput({ principalId: "human-other" }),
      ),
    ).toEqual({ disposition: "invalid" });
    expect((await shard.debugSnapshot()).claims).toEqual([]);
    expect(
      await shard.claimProviderIdentity(claimInput()),
    ).toEqual({ disposition: "claimed" });
  });

  it("never reassigns one provider identity to another participant", async () => {
    expect(
      await shard.claimProviderIdentity(claimInput()),
    ).toEqual({ disposition: "claimed" });
    const otherPrincipal = "human-other";
    const otherParticipantKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      otherPrincipal,
    );
    expect(
      await shard.claimProviderIdentity(
        claimInput({
          participantKey: otherParticipantKey,
          principalId: otherPrincipal,
          attemptId: crypto.randomUUID(),
          now: plusMs(1_000),
        }),
      ),
    ).toEqual({ disposition: "provider_identity_conflict" });
  });

  it("fails closed at bounded owner capacity without mutating a claim", async () => {
    await runInDurableObject(
      shard,
      async (_instance, state) => {
        for (
          let index = 0;
          index < MAX_PROVIDER_IDENTITIES_PER_SHARD;
          index += 1
        ) {
          state.storage.sql.exec(
            `INSERT INTO provider_identity_claims (
               provider_identity_key, provider_participant_id,
               participant_key, first_attempt_id, last_attempt_id,
               created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
            `seed-key-${index}`,
            `seed-provider-${index}`,
            `seed-participant-${index}`,
            crypto.randomUUID(),
            crypto.randomUUID(),
            NOW,
            NOW,
          );
        }
      },
    );
    expect(
      await shard.claimProviderIdentity(claimInput()),
    ).toEqual({ disposition: "capacity" });
    expect(
      (await shard.debugSnapshot()).claims,
    ).toHaveLength(MAX_PROVIDER_IDENTITIES_PER_SHARD);
  });

  function claimInput(
    overrides: Partial<ProviderIdentityClaimInput> = {},
  ): ProviderIdentityClaimInput {
    return {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      providerMeetingId: MEETING_ID,
      shardIndex,
      providerIdentityKey,
      providerParticipantId: PROVIDER_PARTICIPANT_ID,
      participantKey,
      principalId: "human-carter",
      attemptId: crypto.randomUUID(),
      now: NOW,
      ...overrides,
    };
  }
});

function plusMs(milliseconds: number): string {
  return new Date(Date.parse(NOW) + milliseconds).toISOString();
}

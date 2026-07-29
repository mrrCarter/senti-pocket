import { env } from "cloudflare:workers";
import {
  createExecutionContext,
  reset,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type {
  RoomRecord,
  RoomRosterPage,
  RoomRosterParticipant,
  WebhookEventSummary,
} from "../src/contracts";
import type { RuntimeEnv } from "../src/env";
import {
  deriveParticipantId,
  deriveRoomId,
} from "../src/identity";
import {
  rosterShardIndex,
  rosterShardName,
} from "../src/roster-cursor";

const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const TENANT_ID = "tenant-demo";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const ROOM_SECRET = "room-key-test-secret-at-least-thirty-two-characters";
const IDENTITY_SECRET =
  "identity-test-secret-at-least-thirty-two-characters";
const BEARER = "senti-test-bearer-token-123456789";

interface RosterResponse {
  requestId: string;
  page: RoomRosterPage;
}

describe("sharded server-authoritative roster read model", () => {
  let testEnv: RuntimeEnv;
  let room: RoomRecord;
  let roomId: string;
  let tenantId: string;

  beforeEach(async () => {
    await reset();
    tenantId = TENANT_ID;
    testEnv = environment();
    roomId = await deriveRoomId(
      ROOM_SECRET,
      TENANT_ID,
      SESSION_ID,
      EPOCH,
    );
    const governor = testEnv.ROOMS.getByName(roomId);
    const now = "2026-07-29T12:00:00.000Z";
    const reservation = await governor.reserveProvision(
      TENANT_ID,
      SESSION_ID,
      EPOCH,
      roomId,
      "post-meeting",
      now,
      10_000,
    );
    if (reservation.disposition !== "acquired") {
      throw new Error("Failed to seed room.");
    }
    const completed = await governor.completeProvision(
      reservation.fence,
      MEETING_ID,
      now,
    );
    if (!completed) throw new Error("Failed to complete room.");
    room = completed;

    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const request = new Request(input);
        const url = new URL(request.url);
        if (url.pathname === "/api/v1/auth/me") {
          return Response.json({
            id: "roster-reader",
            githubUsername: "reader",
          });
        }
        if (url.pathname === `/api/v1/sessions/${SESSION_ID}`) {
          return Response.json({
            session: {
              id: SESSION_ID,
              tenantId,
              membershipRole: "viewer",
            },
          });
        }
        throw new Error(`Unexpected fetch: ${request.url}`);
      }),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("pages one revision-vector snapshot without treating provider IDs as principals", async () => {
    const expectedPrincipals = new Set<string>();
    for (let index = 0; index < 19; index += 1) {
      const principalId = `human-roster-${index.toString().padStart(2, "0")}`;
      expectedPrincipals.add(principalId);
      await bindAndJoin(principalId, index);
    }

    const participants: RoomRosterParticipant[] = [];
    const snapshotIds = new Set<string>();
    let cursor: string | undefined;
    let expectedPageIndex = 0;
    for (let request = 0; request < 64; request += 1) {
      const response = await rosterRequest({
        requestId: `request-roster-${request.toString().padStart(4, "0")}`,
        ...(cursor ? { cursor } : { pageSize: 3 }),
      });
      expect(response.status).toBe(200);
      const payload = await response.json<RosterResponse>();
      expect(payload.page.schemaVersion).toBe("senti.voice_roster.page.v1");
      expect(payload.page.pageIndex).toBe(expectedPageIndex);
      expect(payload.page.joinedCount).toBe(19);
      expect(payload.page.participants.length).toBeGreaterThan(0);
      snapshotIds.add(payload.page.snapshotId);
      participants.push(...payload.page.participants);

      if (payload.page.complete) {
        expect(payload.page.nextCursor).toBeNull();
        break;
      }
      expect(payload.page.nextCursor).toMatch(/^r1\./);
      cursor = payload.page.nextCursor ?? undefined;
      expectedPageIndex += 1;
    }

    expect(snapshotIds.size).toBe(1);
    expect(participants).toHaveLength(19);
    expect(new Set(participants.map((item) => item.principalId))).toEqual(
      expectedPrincipals,
    );
    expect(
      new Set(participants.map((item) => item.providerCorrelationId)).size,
    ).toBe(19);
    expect(
      participants.every(
        (item) =>
          item.principalId !== item.providerCorrelationId &&
          item.providerCorrelationId.startsWith("senti_") &&
          item.providerSessionId.startsWith("provider-session-") &&
          item.providerPeerId.startsWith("peer-"),
      ),
    ).toBe(true);
    const serialized = JSON.stringify(participants);
    expect(serialized).not.toContain(BEARER);
    expect(serialized).not.toContain(IDENTITY_SECRET);
    expect(serialized).not.toContain(ROOM_SECRET);
  });

  it("requires resync when a shard changes between pages", async () => {
    const pair = await principalsInSameShard();
    const first = await bindAndJoin(pair[0], 100);
    await bindAndJoin(pair[1], 101);

    const firstResponse = await rosterRequest({
      requestId: "request-roster-stale-0001",
      pageSize: 1,
    });
    expect(firstResponse.status).toBe(200);
    const firstPayload = await firstResponse.json<RosterResponse>();
    expect(firstPayload.page.complete).toBe(false);
    expect(firstPayload.page.nextCursor).toMatch(/^r1\./);

    const shard = shardFor(first.participantKey);
    const left = await shard.applyPresence({
      room,
      shardIndex: first.shardIndex,
      event: presenceEvent({
        deliveryId: "delivery-roster-left-stale-0001",
        digest: "digest-roster-left-stale-0001",
        eventName: "meeting.participantLeft",
        participantKey: first.participantKey,
        providerSessionId: first.providerSessionId,
        peerId: first.peerId,
        joinedAt: first.joinedAt,
        leftAt: "2026-07-29T12:30:00.000Z",
      }),
      now: "2026-07-29T12:30:00.000Z",
    });
    expect(left).toBe("applied");

    const stale = await rosterRequest({
      requestId: "request-roster-stale-0002",
      cursor: firstPayload.page.nextCursor!,
    });
    expect(stale.status).toBe(409);
    expect(await stale.json()).toMatchObject({
      error: {
        code: "VOICE_STREAM_RESYNC_REQUIRED",
        recoverable: true,
        retryAfterMs: 0,
      },
    });
  });

  it("rejects a forged cursor and a cross-tenant room lookup", async () => {
    const pair = await principalsInSameShard();
    await bindAndJoin(pair[0], 200);
    await bindAndJoin(pair[1], 201);
    const first = await rosterRequest({
      requestId: "request-roster-forge-0001",
      pageSize: 1,
    });
    const payload = await first.json<RosterResponse>();
    const cursor = payload.page.nextCursor;
    expect(cursor).toBeTruthy();
    const forged = `${cursor!.slice(0, -1)}${cursor!.endsWith("A") ? "B" : "A"}`;

    const rejected = await rosterRequest({
      requestId: "request-roster-forge-0002",
      cursor: forged,
    });
    expect(rejected.status).toBe(422);
    expect(await rejected.json()).toMatchObject({
      error: { code: "VOICE_BAD_REQUEST", recoverable: false },
    });

    tenantId = "tenant-other";
    const isolated = await rosterRequest({
      requestId: "request-roster-tenant-0001",
      pageSize: 10,
    });
    expect(isolated.status).toBe(404);
    expect(await isolated.json()).toMatchObject({
      error: { code: "VOICE_ROOM_NOT_FOUND", recoverable: false },
    });
  });

  it("keeps a newer peer active across stale joins and old-peer leaves", async () => {
    const principalId = "human-generation-fence";
    const participantKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      principalId,
    );
    const shardIndex = rosterShardIndex(participantKey);
    const shard = shardFor(participantKey);
    expect(
      await shard.bindParticipant({
        room,
        shardIndex,
        participantKey,
        principalId,
        providerParticipantId: "provider-generation-fence",
        kind: "human",
        role: "listener",
        displayName: "Generation Fence",
        now: "2026-07-29T12:00:00.000Z",
      }),
    ).toBe("applied");

    const newer = presenceEvent({
      deliveryId: "delivery-newer-join-0001",
      digest: "digest-newer-join-0001",
      eventName: "meeting.participantJoined",
      participantKey,
      providerSessionId: "provider-session-newer",
      peerId: "peer-newer",
      joinedAt: "2026-07-29T12:10:00.000Z",
    });
    expect(
      await shard.applyPresence({
        room,
        shardIndex,
        event: newer,
        now: "2026-07-29T12:10:00.000Z",
      }),
    ).toBe("applied");

    const stale = presenceEvent({
      deliveryId: "delivery-stale-join-0001",
      digest: "digest-stale-join-0001",
      eventName: "meeting.participantJoined",
      participantKey,
      providerSessionId: "provider-session-older",
      peerId: "peer-older",
      joinedAt: "2026-07-29T12:05:00.000Z",
    });
    expect(
      await shard.applyPresence({
        room,
        shardIndex,
        event: stale,
        now: "2026-07-29T12:11:00.000Z",
      }),
    ).toBe("ignored");
    const beforeOldLeave = await shard.describe(
      room,
      "2026-07-29T12:11:00.000Z",
    );
    expect(beforeOldLeave).toMatchObject({
      disposition: "ok",
      descriptor: { joinedCount: 1 },
    });

    const oldLeave = presenceEvent({
      deliveryId: "delivery-old-leave-0001",
      digest: "digest-old-leave-0001",
      eventName: "meeting.participantLeft",
      participantKey,
      providerSessionId: "provider-session-older",
      peerId: "peer-older",
      joinedAt: "2026-07-29T12:05:00.000Z",
      leftAt: "2026-07-29T12:12:00.000Z",
    });
    expect(
      await shard.applyPresence({
        room,
        shardIndex,
        event: oldLeave,
        now: "2026-07-29T12:12:00.000Z",
      }),
    ).toBe("ignored");
    const page = await shard.page(
      room,
      beforeOldLeave.disposition === "ok"
        ? beforeOldLeave.descriptor.revision
        : -1,
      null,
      10,
      "2026-07-29T12:12:00.000Z",
    );
    expect(page).toMatchObject({
      disposition: "ok",
      participants: [
        {
          principalId,
          providerSessionId: "provider-session-newer",
          providerPeerId: "peer-newer",
        },
      ],
    });

    expect(
      await shard.applyPresence({
        room,
        shardIndex,
        event: oldLeave,
        now: "2026-07-29T12:13:00.000Z",
      }),
    ).toBe("duplicate");
    expect(
      await shard.applyPresence({
        room,
        shardIndex,
        event: { ...oldLeave, digest: "different-digest" },
        now: "2026-07-29T12:13:00.000Z",
      }),
    ).toBe("digest_conflict");
  });

  it("refuses to bind one principal to a second provider correlation key", async () => {
    const pair = await principalsInSameShard();
    const firstKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      pair[0],
    );
    const secondKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      pair[1],
    );
    const shardIndex = rosterShardIndex(firstKey);
    const shard = shardFor(firstKey);
    expect(
      await shard.bindParticipant({
        room,
        shardIndex,
        participantKey: firstKey,
        principalId: "human-canonical",
        providerParticipantId: "provider-canonical-one",
        kind: "human",
        role: "listener",
        displayName: "Canonical",
        now: "2026-07-29T12:00:00.000Z",
      }),
    ).toBe("applied");
    expect(
      await shard.bindParticipant({
        room,
        shardIndex,
        participantKey: secondKey,
        principalId: "human-canonical",
        providerParticipantId: "provider-canonical-two",
        kind: "human",
        role: "listener",
        displayName: "Canonical",
        now: "2026-07-29T12:01:00.000Z",
      }),
    ).toBe("binding_conflict");
  });

  async function bindAndJoin(principalId: string, index: number) {
    const participantKey = await deriveParticipantId(
      IDENTITY_SECRET,
      roomId,
      principalId,
    );
    const shardIndex = rosterShardIndex(participantKey);
    const providerSessionId = `provider-session-${index}`;
    const peerId = `peer-${index}`;
    const joinedAt = new Date(
      Date.parse("2026-07-29T12:00:00.000Z") + index * 1_000,
    ).toISOString();
    const shard = shardFor(participantKey);
    const binding = await shard.bindParticipant({
      room,
      shardIndex,
      participantKey,
      principalId,
      providerParticipantId: `provider-participant-${index}`,
      kind: "human",
      role: index % 3 === 0 ? "speaker" : "listener",
      displayName: `Person ${index}`,
      now: joinedAt,
    });
    expect(["applied", "duplicate"]).toContain(binding);
    const presence = await shard.applyPresence({
      room,
      shardIndex,
      event: presenceEvent({
        deliveryId: `delivery-roster-join-${index}`,
        digest: `digest-roster-join-${index}`,
        eventName: "meeting.participantJoined",
        participantKey,
        providerSessionId,
        peerId,
        joinedAt,
      }),
      now: joinedAt,
    });
    expect(["applied", "duplicate"]).toContain(presence);
    return {
      participantKey,
      shardIndex,
      providerSessionId,
      peerId,
      joinedAt,
    };
  }

  async function principalsInSameShard(): Promise<[string, string]> {
    const seen = new Map<number, string>();
    for (let index = 0; index < 256; index += 1) {
      const principal = `human-same-shard-${index}`;
      const participantKey = await deriveParticipantId(
        IDENTITY_SECRET,
        roomId,
        principal,
      );
      const shardIndex = rosterShardIndex(participantKey);
      const existing = seen.get(shardIndex);
      if (existing) return [existing, principal];
      seen.set(shardIndex, principal);
    }
    throw new Error("Could not find a same-shard pair.");
  }

  function shardFor(participantKey: string) {
    const shardIndex = rosterShardIndex(participantKey);
    return testEnv.ROOM_ROSTER_SHARDS.getByName(
      rosterShardName(roomId, shardIndex),
    );
  }

  async function rosterRequest(
    input: {
      requestId: string;
      cursor?: string;
      pageSize?: number;
    },
  ): Promise<Response> {
    const ctx = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://worker.test/v1/voice-rooms/roster", {
        method: "POST",
        headers: {
          authorization: `Bearer ${BEARER}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          sessionId: SESSION_ID,
          roomEpoch: EPOCH,
          ...input,
        }),
      }) as never,
      testEnv,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    return response;
  }

  function environment(): RuntimeEnv {
    return {
      ...(env as unknown as RuntimeEnv),
      SENTI_API_BASE_URL: "https://senti.test",
      REALTIMEKIT_API_BASE_URL: "https://api.cloudflare.test/client/v4",
      REALTIMEKIT_ACCOUNT_ID: "023e105f4ecef8ad9ca31a8372d0c353",
      REALTIMEKIT_APP_ID: "6f80f956-3195-489a-aa76-9f26d3234160",
      REALTIMEKIT_PRESET_MODERATOR: "senti-moderator",
      REALTIMEKIT_PRESET_SPEAKER: "senti-speaker",
      REALTIMEKIT_PRESET_LISTENER: "senti-listener",
      REALTIMEKIT_WEBHOOK_PUBLIC_KEY_URL:
        "https://keys.cloudflare.test/webhooks.json",
      TRANSCRIPTION_MODE: "post-meeting",
      TRANSCRIPTION_NEURONS_PER_AUDIO_MINUTE: "836.36",
      OUTBOUND_TIMEOUT_MS: "5000",
      MAX_CONTROL_REQUESTS_PER_ROOM_PER_DAY: "10000",
      CLOUDFLARE_API_TOKEN:
        "cloudflare-test-token-never-client-visible",
      ROOM_KEY_HMAC_SECRET: ROOM_SECRET,
      IDENTITY_HMAC_SECRET: IDENTITY_SECRET,
    };
  }
});

function presenceEvent(input: {
  deliveryId: string;
  digest: string;
  eventName:
    | "meeting.participantJoined"
    | "meeting.participantLeft";
  participantKey: string;
  providerSessionId: string;
  peerId: string;
  joinedAt: string;
  leftAt?: string;
}): WebhookEventSummary {
  return {
    deliveryId: input.deliveryId,
    digest: input.digest,
    eventName: input.eventName,
    providerMeetingId: MEETING_ID,
    providerSessionId: input.providerSessionId,
    peerId: input.peerId,
    customParticipantId: input.participantKey,
    participantJoinedAt: input.joinedAt,
    participantLeftAt: input.leftAt ?? null,
    occurredAt: input.leftAt ?? input.joinedAt,
  };
}

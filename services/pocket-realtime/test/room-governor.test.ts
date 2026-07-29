import { env } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { VOICE_CONTROL_QUEUE_SCHEMA } from "../src/contracts";
import type { RuntimeEnv } from "../src/env";
import { deriveRoomId } from "../src/identity";

const TENANT_ID = "tenant-demo";
const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const ROOM_SECRET = "room-key-test-secret-at-least-thirty-two-characters";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const NOW = "2026-07-29T08:20:00.000Z";

describe("RoomGovernor invariants", () => {
  beforeEach(async () => {
    await reset();
  });

  it("fails closed on a room identity mismatch", async () => {
    const testEnv = env as unknown as RuntimeEnv;
    const roomId = await deriveRoomId(
      ROOM_SECRET,
      TENANT_ID,
      SESSION_ID,
      EPOCH,
    );
    const governor = testEnv.ROOMS.getByName(roomId);
    const first = await governor.reserveProvision(
      TENANT_ID,
      SESSION_ID,
      EPOCH,
      roomId,
      "post-meeting",
      NOW,
      10,
    );
    expect(first.disposition).toBe("acquired");

    const mismatch = await governor.reserveProvision(
      "tenant-other",
      SESSION_ID,
      EPOCH,
      roomId,
      "post-meeting",
      NOW,
      10,
    );
    expect(mismatch.disposition).toBe("identity_mismatch");
  });

  it("stops exactly at the daily control budget without growing the counter", async () => {
    const testEnv = env as unknown as RuntimeEnv;
    const roomId = await deriveRoomId(
      ROOM_SECRET,
      TENANT_ID,
      SESSION_ID,
      EPOCH,
    );
    const governor = testEnv.ROOMS.getByName(roomId);
    const provision = await governor.reserveProvision(
      TENANT_ID,
      SESSION_ID,
      EPOCH,
      roomId,
      "post-meeting",
      NOW,
      2,
    );
    if (provision.disposition !== "acquired") {
      throw new Error("Expected provision reservation.");
    }
    await governor.completeProvision(provision.fence, MEETING_ID, NOW);

    expect(
      await governor.getRoom(TENANT_ID, SESSION_ID, EPOCH, roomId),
    ).not.toBeNull();
    const admission = await governor.reserveAdmission(
      "participant-one",
      "principal-one",
      "viewer",
      "listener",
      NOW,
      2,
    );
    expect(admission.disposition).toBe("create");
    expect(
      (
        await governor.reserveAdmission(
          "participant-two",
          "principal-two",
          "viewer",
          "listener",
          NOW,
          2,
        )
      ).disposition,
    ).toBe("over_budget");
    expect(
      (
        await governor.reserveAdmission(
          "participant-three",
          "principal-three",
          "viewer",
          "listener",
          NOW,
          2,
        )
      ).disposition,
    ).toBe("over_budget");

    expect((await governor.debugSnapshot()).controlRequests).toBe(2);
  });

  it("advances one revision for one command and fences exact retries", async () => {
    const { governor, input } = await setupModerationGovernor();
    const first = await governor.reserveModeration(input);
    expect(first.disposition).toBe("accepted");
    if (first.disposition !== "accepted") {
      throw new Error("Expected accepted command intent.");
    }
    expect(first.command.controlRevision).toBe(1);

    const pendingReplay = await governor.reserveModeration(input);
    expect(pendingReplay).toEqual({
      disposition: "replay",
      command: first.command,
    });

    const execution = await governor.reserveModerationExecution(
      {
        schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
        roomId: input.roomId,
        commandId: input.commandId,
        controlRevision: 1,
      },
      NOW,
    );
    if (execution.disposition !== "execute") {
      throw new Error("Expected command execution lease.");
    }
    const finalized = await governor.finalizeModerationUnsupported(
      input.commandId,
      execution.fence,
      NOW,
    );
    expect(finalized).toMatchObject({
      status: "unsupported",
      controlRevision: 1,
      providerMutationApplied: false,
      resultCode: "executor_unavailable",
    });

    const replay = await governor.reserveModeration(input);
    expect(replay.disposition).toBe("replay");
    if (replay.disposition !== "replay") {
      throw new Error("Expected exact command replay.");
    }
    expect(replay.command).toEqual(finalized);

    const conflicting = await governor.reserveModeration({
      ...input,
      payloadHash: "different-payload-hash",
    });
    expect(conflicting.disposition).toBe("idempotency_conflict");

    const differentOwner = await governor.reserveModeration({
      ...input,
      actorPrincipalId: "principal-other",
      actorMembershipRole: "admin",
    });
    expect(differentOwner.disposition).toBe("idempotency_conflict");

    const stale = await governor.reserveModeration({
      ...input,
      commandId: "command-0002",
      idempotencyHash: "idempotency-hash-0002",
      payloadHash: "payload-hash-0002",
    });
    expect(stale).toEqual({
      disposition: "revision_conflict",
      currentRevision: 1,
    });

    const snapshot = await governor.debugSnapshot();
    expect(snapshot.room?.controlRevision).toBe(1);
    expect(snapshot.commandCount).toBe(1);
    expect(snapshot.pendingCommandCount).toBe(0);
    expect(snapshot.pendingOutboxCount).toBe(0);
    expect(snapshot.controlRequests).toBe(4);
  });

  it("serializes concurrent commands at one expected revision", async () => {
    const { governor, input } = await setupModerationGovernor();
    const commands = await Promise.all([
      governor.reserveModeration(input),
      governor.reserveModeration({
        ...input,
        commandId: "command-0002",
        idempotencyHash: "idempotency-hash-0002",
        payloadHash: "payload-hash-0002",
        action: "remove",
      }),
    ]);

    expect(
      commands.filter((result) => result.disposition === "accepted"),
    ).toHaveLength(1);
    expect(
      commands.filter((result) => result.disposition === "revision_conflict"),
    ).toHaveLength(1);
    const executable = commands.find(
      (result) => result.disposition === "accepted",
    );
    if (!executable || executable.disposition !== "accepted") {
      throw new Error("Expected exactly one accepted command intent.");
    }
    expect(executable.command.controlRevision).toBe(1);
    const execution = await governor.reserveModerationExecution(
      {
        schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
        roomId: input.roomId,
        commandId: executable.command.commandId,
        controlRevision: executable.command.controlRevision,
      },
      NOW,
    );
    if (execution.disposition !== "execute") {
      throw new Error("Expected exactly one command execution lease.");
    }
    expect(
      await governor.finalizeModerationUnsupported(
        executable.command.commandId,
        execution.fence,
        NOW,
      ),
    ).toMatchObject({
      status: "unsupported",
      controlRevision: 1,
      providerMutationApplied: false,
    });

    const snapshot = await governor.debugSnapshot();
    expect(snapshot.room?.controlRevision).toBe(1);
    expect(snapshot.commandCount).toBe(1);
    expect(snapshot.pendingCommandCount).toBe(0);
  });

  it("rechecks authority and target binding before reacquiring an expired lease", async () => {
    const { governor, input } = await setupModerationGovernor();
    const first = await governor.reserveModeration(input);
    if (first.disposition !== "accepted") {
      throw new Error("Expected accepted command intent.");
    }
    const execution = await governor.reserveModerationExecution(
      {
        schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
        roomId: input.roomId,
        commandId: input.commandId,
        controlRevision: first.command.controlRevision,
      },
      NOW,
    );
    if (execution.disposition !== "execute") {
      throw new Error("Expected command execution lease.");
    }
    const afterLease = "2026-07-29T08:20:16.000Z";

    const revoked = await governor.reserveModeration({
      ...input,
      actorMembershipRole: "viewer",
      now: afterLease,
    });
    expect(revoked).toEqual({
      disposition: "not_authorized",
      currentRevision: 1,
    });

    const targetRefresh = await governor.reserveAdmission(
      "participant-target",
      "principal-target",
      "viewer",
      "listener",
      afterLease,
      20,
    );
    if (
      targetRefresh.disposition !== "create" &&
      targetRefresh.disposition !== "refresh" &&
      targetRefresh.disposition !== "update"
    ) {
      throw new Error("Expected target refresh reservation.");
    }
    await governor.completeAdmission(
      "participant-target",
      targetRefresh.fence,
      "provider-target-rebound",
      afterLease,
    );

    const rebound = await governor.reserveModeration({
      ...input,
      now: afterLease,
    });
    expect(rebound).toEqual({
      disposition: "target_not_found",
      currentRevision: 1,
    });

    const snapshot = await governor.debugSnapshot();
    expect(snapshot.room?.controlRevision).toBe(1);
    expect(snapshot.commandCount).toBe(1);
    expect(snapshot.pendingCommandCount).toBe(1);
  });
});

async function setupModerationGovernor() {
  const testEnv = env as unknown as RuntimeEnv;
  const roomId = await deriveRoomId(
    ROOM_SECRET,
    TENANT_ID,
    SESSION_ID,
    EPOCH,
  );
  const governor = testEnv.ROOMS.getByName(roomId);
  const provision = await governor.reserveProvision(
    TENANT_ID,
    SESSION_ID,
    EPOCH,
    roomId,
    "post-meeting",
    NOW,
    20,
  );
  if (provision.disposition !== "acquired") {
    throw new Error("Expected provision reservation.");
  }
  await governor.completeProvision(provision.fence, MEETING_ID, NOW);

  const actor = await governor.reserveAdmission(
    "participant-actor",
    "principal-actor",
    "owner",
    "moderator",
    NOW,
    20,
  );
  if (
    actor.disposition !== "create" &&
    actor.disposition !== "refresh" &&
    actor.disposition !== "update"
  ) {
    throw new Error("Expected actor admission.");
  }
  await governor.completeAdmission(
    "participant-actor",
    actor.fence,
    "provider-actor",
    NOW,
  );

  const target = await governor.reserveAdmission(
    "participant-target",
    "principal-target",
    "viewer",
    "listener",
    NOW,
    20,
  );
  if (
    target.disposition !== "create" &&
    target.disposition !== "refresh" &&
    target.disposition !== "update"
  ) {
    throw new Error("Expected target admission.");
  }
  await governor.completeAdmission(
    "participant-target",
    target.fence,
    "provider-target",
    NOW,
  );

  return {
    governor,
    input: {
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      actorPrincipalId: "principal-actor",
      actorMembershipRole: "owner" as const,
      targetPrincipalId: "principal-target",
      action: "mute" as const,
      commandId: "command-0001",
      idempotencyHash: "idempotency-hash-0001",
      payloadHash: "payload-hash-0001",
      expectedRevision: 0,
      now: NOW,
      maxDailyRequests: 20,
    },
  };
}

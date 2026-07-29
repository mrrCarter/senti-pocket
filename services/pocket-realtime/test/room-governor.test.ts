import { env } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
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
      "listener",
      NOW,
      2,
    );
    expect(admission.disposition).toBe("create");
    expect(
      (
        await governor.reserveAdmission(
          "participant-two",
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
          "listener",
          NOW,
          2,
        )
      ).disposition,
    ).toBe("over_budget");

    expect((await governor.debugSnapshot()).controlRequests).toBe(2);
  });
});

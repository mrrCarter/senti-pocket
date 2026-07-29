import { describe, expect, it } from "vitest";
import {
  deriveParticipantId,
  deriveRoomId,
  meetingTitle,
  roleForMembership,
  roomIdFromMeetingTitle,
} from "../src/identity";

const SECRET = "test-domain-separated-hmac-secret-that-is-long-enough";

describe("provider-neutral identity and role policy", () => {
  it("derives opaque stable room and participant identifiers", async () => {
    const room = await deriveRoomId(
      SECRET,
      "tenant-demo",
      "6cf7e861-546a-4b9f-b937-39182a5bd395",
      "5a73635c-cbd2-4e22-b24e-9a31520a939c",
    );
    const participant = await deriveParticipantId(
      SECRET,
      room,
      "human-carter@example.invalid",
    );

    expect(room).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(participant).toMatch(/^senti_[A-Za-z0-9_-]{43}$/);
    expect(room).not.toContain("6cf7e861");
    expect(participant).not.toContain("carter");
    expect(roomIdFromMeetingTitle(meetingTitle(room))).toBe(room);
  });

  it("allows downgrades but never caller-selected privilege elevation", () => {
    expect(roleForMembership("owner")).toBe("moderator");
    expect(roleForMembership("admin", "listener")).toBe("listener");
    expect(roleForMembership("contributor", "moderator")).toBe("speaker");
    expect(roleForMembership("viewer", "speaker")).toBe("listener");
  });
});

import {
  VOICE_ROSTER_PAGE_SCHEMA,
  type RoomRosterPage,
  type RoomRosterRequest,
} from "./contracts";
import type { RuntimeEnv } from "./env";
import { HttpError, upstreamError } from "./errors";
import {
  type RosterRoomIdentity,
  type RosterShardDescriptor,
} from "./room-roster-shard";
import {
  DEFAULT_ROSTER_PAGE_SIZE,
  ROSTER_CURSOR_LIFETIME_MS,
  ROSTER_SHARD_COUNT,
  decodeRosterCursor,
  encodeRosterCursor,
  rosterShardName,
  rosterSnapshotId,
  type RosterCursorState,
} from "./roster-cursor";

export interface AuthorizedRosterRequest extends RoomRosterRequest {
  tenantId: string;
  roomId: string;
}

export async function readRosterPage(
  env: RuntimeEnv,
  input: AuthorizedRosterRequest,
  now: Date,
): Promise<RoomRosterPage> {
  let state: RosterCursorState;
  let room: RosterRoomIdentity;

  if (input.cursor) {
    state = await decodeRosterCursor(
      env.IDENTITY_HMAC_SECRET,
      input.cursor,
      input.roomId,
      now.getTime(),
    );
    if (
      state.tenantId !== input.tenantId ||
      state.sessionId !== input.sessionId ||
      state.roomEpoch !== input.roomEpoch ||
      (input.pageSize !== undefined && input.pageSize !== state.pageSize)
    ) {
      throw new HttpError(
        422,
        "invalid_roster_cursor",
        "The roster cursor is not valid for this room request.",
      );
    }
    room = roomIdentityFromCursor(state);
  } else {
    const currentRoom = await env.ROOMS.getByName(input.roomId).getRoom(
      input.tenantId,
      input.sessionId,
      input.roomEpoch,
      input.roomId,
    );
    if (!currentRoom) {
      throw new HttpError(404, "room_not_ready", "Voice room is not ready.");
    }
    room = currentRoom;
    const descriptors = await rosterDescriptors(
      env,
      room,
      now.toISOString(),
    );
    const revisions = descriptors.map((item) => item.revision);
    const counts = descriptors.map((item) => item.joinedCount);
    const joinedCount = counts.reduce((sum, count) => sum + count, 0);
    state = {
      version: 1,
      tenantId: room.tenantId,
      sessionId: room.sessionId,
      roomEpoch: room.roomEpoch,
      roomId: room.roomId,
      providerMeetingId: room.providerMeetingId,
      snapshotId: await rosterSnapshotId(input.roomId, revisions),
      revisions,
      counts,
      shardIndex: nextNonemptyShard(counts, 0) ?? 0,
      afterParticipantKey: null,
      pageIndex: 0,
      pageSize: input.pageSize ?? DEFAULT_ROSTER_PAGE_SIZE,
      joinedCount,
      expiresAt: now.getTime() + ROSTER_CURSOR_LIFETIME_MS,
    };
  }

  if (state.joinedCount === 0) {
    await requireUnchangedRosterSnapshot(
      env,
      room,
      state,
      now.toISOString(),
    );
    return rosterPage(state, [], null, true);
  }
  if (state.counts[state.shardIndex] === 0) {
    throw rosterResyncRequired();
  }

  const result = await rosterShard(
    env,
    input.roomId,
    state.shardIndex,
  ).page(
    room,
    state.revisions[state.shardIndex]!,
    state.afterParticipantKey,
    state.pageSize,
    now.toISOString(),
  );
  if (result.disposition === "identity_mismatch") {
    throw upstreamError(
      "roster_projection_conflict",
      "The server-owned voice roster identity could not be reconciled.",
    );
  }
  if (result.disposition === "stale") throw rosterResyncRequired();
  if (
    result.participants.length === 0 &&
    state.afterParticipantKey === null
  ) {
    throw rosterResyncRequired();
  }

  let nextCursor: string | null = null;
  let complete = false;
  if (result.hasMore) {
    if (!result.lastParticipantKey) throw rosterResyncRequired();
    nextCursor = await encodeRosterCursor(
      env.IDENTITY_HMAC_SECRET,
      {
        ...state,
        afterParticipantKey: result.lastParticipantKey,
        pageIndex: state.pageIndex + 1,
      },
    );
  } else {
    const nextShard = nextNonemptyShard(
      state.counts,
      state.shardIndex + 1,
    );
    if (nextShard !== null) {
      nextCursor = await encodeRosterCursor(
        env.IDENTITY_HMAC_SECRET,
        {
          ...state,
          shardIndex: nextShard,
          afterParticipantKey: null,
          pageIndex: state.pageIndex + 1,
        },
      );
    } else {
      await requireUnchangedRosterSnapshot(
        env,
        room,
        state,
        now.toISOString(),
      );
      complete = true;
    }
  }
  return rosterPage(
    state,
    result.participants,
    nextCursor,
    complete,
  );
}

async function rosterDescriptors(
  env: RuntimeEnv,
  room: RosterRoomIdentity,
  now: string,
): Promise<RosterShardDescriptor[]> {
  const results = await Promise.all(
    Array.from({ length: ROSTER_SHARD_COUNT }, (_, shardIndex) =>
      rosterShard(env, room.roomId, shardIndex).describe(room, now),
    ),
  );
  if (results.some((result) => result.disposition !== "ok")) {
    throw upstreamError(
      "roster_projection_conflict",
      "The server-owned voice roster identity could not be reconciled.",
    );
  }
  return results.map((result) => {
    if (result.disposition !== "ok") {
      throw new Error("Roster descriptor narrowed incorrectly.");
    }
    return result.descriptor;
  });
}

async function requireUnchangedRosterSnapshot(
  env: RuntimeEnv,
  room: RosterRoomIdentity,
  state: RosterCursorState,
  now: string,
): Promise<void> {
  const descriptors = await rosterDescriptors(env, room, now);
  const unchanged = descriptors.every(
    (descriptor, index) =>
      descriptor.revision === state.revisions[index] &&
      descriptor.joinedCount === state.counts[index],
  );
  if (!unchanged) throw rosterResyncRequired();
}

function rosterShard(
  env: RuntimeEnv,
  roomId: string,
  shardIndex: number,
) {
  return env.ROOM_ROSTER_SHARDS.getByName(
    rosterShardName(roomId, shardIndex),
  );
}

function nextNonemptyShard(
  counts: readonly number[],
  start: number,
): number | null {
  for (let index = start; index < counts.length; index += 1) {
    if ((counts[index] ?? 0) > 0) return index;
  }
  return null;
}

function roomIdentityFromCursor(
  state: RosterCursorState,
): RosterRoomIdentity {
  return {
    tenantId: state.tenantId,
    sessionId: state.sessionId,
    roomEpoch: state.roomEpoch,
    roomId: state.roomId,
    providerMeetingId: state.providerMeetingId,
  };
}

function rosterPage(
  state: RosterCursorState,
  participants: RoomRosterPage["participants"],
  nextCursor: string | null,
  complete: boolean,
): RoomRosterPage {
  return {
    schemaVersion: VOICE_ROSTER_PAGE_SCHEMA,
    tenantId: state.tenantId,
    sessionId: state.sessionId,
    roomEpoch: state.roomEpoch,
    snapshotId: state.snapshotId,
    pageIndex: state.pageIndex,
    joinedCount: state.joinedCount,
    participants,
    nextCursor,
    complete,
  };
}

function rosterResyncRequired(): HttpError {
  return new HttpError(
    409,
    "roster_resync_required",
    "The voice roster changed while this snapshot was being read.",
  );
}

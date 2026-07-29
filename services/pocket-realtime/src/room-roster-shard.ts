import { DurableObject } from "cloudflare:workers";
import type {
  RoomRecord,
  RoomRosterParticipant,
  VoiceRole,
  WebhookEventSummary,
} from "./contracts";
import type { RuntimeEnv } from "./env";
import {
  MAX_ROSTER_PAGE_SIZE,
  rosterShardIndex,
} from "./roster-cursor";

const DELIVERY_RETENTION_MS = 8 * 24 * 60 * 60 * 1_000;
const MAX_DELIVERIES_PER_SHARD = 4_096;
const MAX_INACTIVE_PEERS_PER_PARTICIPANT = 4;
const PRINCIPAL_ID = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,159}$/;
const PARTICIPANT_KEY = /^senti_[A-Za-z0-9_-]{43}$/;
const OPAQUE_PROVIDER_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;

export interface RosterBindingInput {
  room: RoomRecord;
  shardIndex: number;
  participantKey: string;
  principalId: string;
  providerParticipantId: string;
  kind: "human" | "agent";
  role: VoiceRole;
  displayName: string | null;
  now: string;
}

export interface RosterPresenceInput {
  room: RosterRoomIdentity;
  shardIndex: number;
  event: WebhookEventSummary;
  now: string;
}

export interface RosterRoomIdentity {
  tenantId: string;
  sessionId: string;
  roomEpoch: string;
  roomId: string;
  providerMeetingId: string;
}

export type RosterProjectionDisposition =
  | "applied"
  | "duplicate"
  | "ignored"
  | "identity_mismatch"
  | "binding_conflict"
  | "digest_conflict";

export interface RosterShardDescriptor {
  revision: number;
  joinedCount: number;
}

export type RosterDescriptorResult =
  | { disposition: "ok"; descriptor: RosterShardDescriptor }
  | { disposition: "identity_mismatch" };

export type RosterPageResult =
  | {
      disposition: "ok";
      revision: number;
      participants: RoomRosterParticipant[];
      lastParticipantKey: string | null;
      hasMore: boolean;
    }
  | {
      disposition: "stale";
      descriptor: RosterShardDescriptor;
    }
  | { disposition: "identity_mismatch" };

interface RosterRoomRow {
  [key: string]: SqlStorageValue;
  singleton: 1;
  tenant_id: string;
  senti_session_id: string;
  room_epoch: string;
  room_id: string;
  provider_meeting_id: string;
  revision: number;
  created_at: string;
  updated_at: string;
}

interface RosterBindingRow {
  [key: string]: SqlStorageValue;
  participant_key: string;
  principal_id: string;
  provider_participant_id: string;
  kind: "human" | "agent";
  role: VoiceRole;
  display_name: string | null;
  updated_at: string;
}

interface RosterPeerRow {
  [key: string]: SqlStorageValue;
  provider_session_id: string;
  peer_id: string;
  participant_key: string;
  joined_at: string;
  left_at: string | null;
  active: 0 | 1;
  updated_at: string;
}

interface RosterDeliveryRow {
  [key: string]: SqlStorageValue;
  digest: string;
}

interface RosterPageRow extends RosterBindingRow {
  provider_session_id: string;
  peer_id: string;
  joined_at: string;
}

export class RoomRosterShard extends DurableObject<RuntimeEnv> {
  constructor(ctx: DurableObjectState, env: RuntimeEnv) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS roster_room (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          tenant_id TEXT NOT NULL,
          senti_session_id TEXT NOT NULL,
          room_epoch TEXT NOT NULL,
          room_id TEXT NOT NULL,
          provider_meeting_id TEXT NOT NULL,
          revision INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          CHECK (revision >= 0)
        );
        CREATE TABLE IF NOT EXISTS roster_bindings (
          participant_key TEXT PRIMARY KEY,
          principal_id TEXT NOT NULL UNIQUE,
          provider_participant_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          role TEXT NOT NULL,
          display_name TEXT,
          updated_at TEXT NOT NULL,
          CHECK (kind IN ('human', 'agent')),
          CHECK (role IN ('moderator', 'speaker', 'listener'))
        );
        CREATE INDEX IF NOT EXISTS roster_bindings_provider_participant
          ON roster_bindings(provider_participant_id);
        CREATE TABLE IF NOT EXISTS roster_peers (
          provider_session_id TEXT NOT NULL,
          peer_id TEXT NOT NULL,
          participant_key TEXT NOT NULL,
          joined_at TEXT NOT NULL,
          left_at TEXT,
          active INTEGER NOT NULL DEFAULT 1,
          updated_at TEXT NOT NULL,
          PRIMARY KEY (provider_session_id, peer_id),
          CHECK (active IN (0, 1))
        );
        CREATE UNIQUE INDEX IF NOT EXISTS roster_peers_one_active
          ON roster_peers(participant_key)
          WHERE active = 1;
        CREATE INDEX IF NOT EXISTS roster_peers_by_participant
          ON roster_peers(participant_key, active, joined_at);
        CREATE TABLE IF NOT EXISTS roster_deliveries (
          delivery_id TEXT PRIMARY KEY,
          digest TEXT NOT NULL,
          received_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS roster_deliveries_received
          ON roster_deliveries(received_at);
      `);
    });
  }

  bindParticipant(input: RosterBindingInput): RosterProjectionDisposition {
    return this.ctx.storage.transactionSync(() => {
      if (!validBinding(input)) return "binding_conflict";
      if (rosterShardIndex(input.participantKey) !== input.shardIndex) {
        return "binding_conflict";
      }
      if (!this.ensureRoom(input.room, input.now)) {
        return "identity_mismatch";
      }

      const existing = this.bindingByParticipant(input.participantKey);
      const principalBinding = this.bindingByPrincipal(input.principalId);
      if (
        (existing &&
          (existing.principal_id !== input.principalId ||
            existing.provider_participant_id !==
              input.providerParticipantId ||
            existing.kind !== input.kind)) ||
        (principalBinding &&
          principalBinding.participant_key !== input.participantKey)
      ) {
        return "binding_conflict";
      }

      if (
        existing &&
        existing.role === input.role &&
        existing.display_name === input.displayName
      ) {
        return "duplicate";
      }
      if (existing) {
        this.ctx.storage.sql.exec(
          `UPDATE roster_bindings
           SET role = ?, display_name = ?, updated_at = ?
           WHERE participant_key = ?`,
          input.role,
          input.displayName,
          input.now,
          input.participantKey,
        );
      } else {
        this.ctx.storage.sql.exec(
          `INSERT INTO roster_bindings (
             participant_key, principal_id, provider_participant_id,
             kind, role, display_name, updated_at
           ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
          input.participantKey,
          input.principalId,
          input.providerParticipantId,
          input.kind,
          input.role,
          input.displayName,
          input.now,
        );
      }
      this.bumpRevision(input.now);
      return "applied";
    });
  }

  applyPresence(input: RosterPresenceInput): RosterProjectionDisposition {
    return this.ctx.storage.transactionSync(() => {
      const { event } = input;
      if (
        !event.customParticipantId ||
        !PARTICIPANT_KEY.test(event.customParticipantId) ||
        rosterShardIndex(event.customParticipantId) !== input.shardIndex
      ) {
        return "ignored";
      }
      if (!this.ensureRoom(input.room, input.now)) {
        return "identity_mismatch";
      }
      const delivery = this.delivery(event.deliveryId);
      if (delivery?.digest !== undefined && delivery.digest !== event.digest) {
        return "digest_conflict";
      }
      if (delivery) return "duplicate";

      this.ctx.storage.sql.exec(
        `INSERT INTO roster_deliveries (delivery_id, digest, received_at)
         VALUES (?, ?, ?)`,
        event.deliveryId,
        event.digest,
        input.now,
      );
      let changed = false;
      if (event.eventName === "meeting.participantJoined") {
        changed = this.recordJoined(event, input.now);
      } else if (event.eventName === "meeting.participantLeft") {
        changed = this.recordLeft(event, input.now);
      }
      if (changed) this.bumpRevision(input.now);
      this.pruneDeliveries(input.now);
      this.prunePeerHistory(event.customParticipantId);
      return changed ? "applied" : "ignored";
    });
  }

  describe(room: RosterRoomIdentity, now: string): RosterDescriptorResult {
    return this.ctx.storage.transactionSync(() => {
      if (!this.ensureRoom(room, now)) {
        return { disposition: "identity_mismatch" };
      }
      return {
        disposition: "ok",
        descriptor: this.currentDescriptor(),
      };
    });
  }

  page(
    room: RosterRoomIdentity,
    expectedRevision: number,
    afterParticipantKey: string | null,
    limit: number,
    now: string,
  ): RosterPageResult {
    return this.ctx.storage.transactionSync(() => {
      if (
        !Number.isSafeInteger(expectedRevision) ||
        expectedRevision < 0 ||
        (afterParticipantKey !== null &&
          !PARTICIPANT_KEY.test(afterParticipantKey)) ||
        !Number.isSafeInteger(limit) ||
        limit < 1 ||
        limit > MAX_ROSTER_PAGE_SIZE
      ) {
        return { disposition: "identity_mismatch" };
      }
      if (!this.ensureRoom(room, now)) {
        return { disposition: "identity_mismatch" };
      }
      const descriptor = this.currentDescriptor();
      if (descriptor.revision !== expectedRevision) {
        return { disposition: "stale", descriptor };
      }
      const rows = this.ctx.storage.sql
        .exec<RosterPageRow>(
          `SELECT bindings.*,
                  peers.provider_session_id,
                  peers.peer_id,
                  peers.joined_at
           FROM roster_bindings AS bindings
           JOIN roster_peers AS peers
             ON peers.participant_key = bindings.participant_key
            AND peers.active = 1
           WHERE bindings.participant_key > ?
           ORDER BY bindings.participant_key
           LIMIT ?`,
          afterParticipantKey ?? "",
          limit + 1,
        )
        .toArray();
      const hasMore = rows.length > limit;
      const visible = hasMore ? rows.slice(0, limit) : rows;
      return {
        disposition: "ok",
        revision: expectedRevision,
        participants: visible.map(toRosterParticipant),
        lastParticipantKey:
          visible[visible.length - 1]?.participant_key ?? null,
        hasMore,
      };
    });
  }

  debugPeers(): Array<{
    participantKey: string;
    providerSessionId: string;
    peerId: string;
    joinedAt: string;
    leftAt: string | null;
    active: boolean;
  }> {
    return this.ctx.storage.sql
      .exec<RosterPeerRow>(
        `SELECT * FROM roster_peers
         ORDER BY participant_key, joined_at, provider_session_id, peer_id`,
      )
      .toArray()
      .map((row) => ({
        participantKey: row.participant_key,
        providerSessionId: row.provider_session_id,
        peerId: row.peer_id,
        joinedAt: row.joined_at,
        leftAt: row.left_at,
        active: row.active === 1,
      }));
  }

  private ensureRoom(room: RosterRoomIdentity, now: string): boolean {
    const existing = this.room();
    if (existing) return matchesRoom(existing, room);
    this.ctx.storage.sql.exec(
      `INSERT INTO roster_room (
         singleton, tenant_id, senti_session_id, room_epoch, room_id,
         provider_meeting_id, revision, created_at, updated_at
       ) VALUES (1, ?, ?, ?, ?, ?, 0, ?, ?)`,
      room.tenantId,
      room.sessionId,
      room.roomEpoch,
      room.roomId,
      room.providerMeetingId,
      now,
      now,
    );
    return true;
  }

  private recordJoined(event: WebhookEventSummary, now: string): boolean {
    if (
      !event.customParticipantId ||
      !event.providerSessionId ||
      !event.peerId ||
      !event.participantJoinedAt
    ) {
      return false;
    }
    const joinedMs = Date.parse(event.participantJoinedAt);
    if (!Number.isFinite(joinedMs)) return false;
    if (this.peer(event.providerSessionId, event.peerId)) return false;

    const active = this.activePeer(event.customParticipantId);
    if (active) {
      const activeJoinedMs = Date.parse(active.joined_at);
      if (!Number.isFinite(activeJoinedMs) || joinedMs <= activeJoinedMs) {
        this.insertInactivePeer(event, now);
        return false;
      }
      this.ctx.storage.sql.exec(
        `UPDATE roster_peers
         SET active = 0, updated_at = ?
         WHERE provider_session_id = ? AND peer_id = ? AND active = 1`,
        now,
        active.provider_session_id,
        active.peer_id,
      );
    } else {
      const latest = this.latestPeer(event.customParticipantId);
      const latestJoinedMs = latest ? Date.parse(latest.joined_at) : NaN;
      if (
        latest &&
        (!Number.isFinite(latestJoinedMs) || joinedMs <= latestJoinedMs)
      ) {
        this.insertInactivePeer(event, now);
        return false;
      }
    }
    this.ctx.storage.sql.exec(
      `INSERT INTO roster_peers (
         provider_session_id, peer_id, participant_key,
         joined_at, left_at, active, updated_at
       ) VALUES (?, ?, ?, ?, NULL, 1, ?)`,
      event.providerSessionId,
      event.peerId,
      event.customParticipantId,
      event.participantJoinedAt,
      now,
    );
    return true;
  }

  private recordLeft(event: WebhookEventSummary, now: string): boolean {
    if (
      !event.customParticipantId ||
      !event.providerSessionId ||
      !event.peerId ||
      !event.participantLeftAt
    ) {
      return false;
    }
    const peer = this.peer(event.providerSessionId, event.peerId);
    if (
      !peer ||
      peer.participant_key !== event.customParticipantId ||
      peer.left_at !== null
    ) {
      return false;
    }
    const joinedMs = Date.parse(peer.joined_at);
    const leftMs = Date.parse(event.participantLeftAt);
    if (
      !Number.isFinite(joinedMs) ||
      !Number.isFinite(leftMs) ||
      leftMs < joinedMs
    ) {
      return false;
    }
    this.ctx.storage.sql.exec(
      `UPDATE roster_peers
       SET left_at = ?, active = 0, updated_at = ?
       WHERE provider_session_id = ? AND peer_id = ?
         AND participant_key = ?`,
      event.participantLeftAt,
      now,
      event.providerSessionId,
      event.peerId,
      event.customParticipantId,
    );
    return peer.active === 1;
  }

  private insertInactivePeer(
    event: WebhookEventSummary,
    now: string,
  ): void {
    this.ctx.storage.sql.exec(
      `INSERT OR IGNORE INTO roster_peers (
         provider_session_id, peer_id, participant_key,
         joined_at, left_at, active, updated_at
       ) VALUES (?, ?, ?, ?, NULL, 0, ?)`,
      event.providerSessionId!,
      event.peerId!,
      event.customParticipantId!,
      event.participantJoinedAt!,
      now,
    );
  }

  private currentDescriptor(): RosterShardDescriptor {
    const revision = this.room()?.revision ?? 0;
    const joined = this.ctx.storage.sql
      .exec<{ count: number }>(
        `SELECT COUNT(*) AS count
         FROM roster_bindings AS bindings
         JOIN roster_peers AS peers
           ON peers.participant_key = bindings.participant_key
          AND peers.active = 1`,
      )
      .one().count;
    return { revision, joinedCount: joined };
  }

  private bumpRevision(now: string): void {
    this.ctx.storage.sql.exec(
      `UPDATE roster_room
       SET revision = revision + 1, updated_at = ?
       WHERE singleton = 1`,
      now,
    );
  }

  private pruneDeliveries(now: string): void {
    const cutoff = new Date(
      Date.parse(now) - DELIVERY_RETENTION_MS,
    ).toISOString();
    this.ctx.storage.sql.exec(
      "DELETE FROM roster_deliveries WHERE received_at < ?",
      cutoff,
    );
    this.ctx.storage.sql.exec(
      `DELETE FROM roster_deliveries
       WHERE delivery_id IN (
         SELECT delivery_id FROM roster_deliveries
         ORDER BY received_at DESC
         LIMIT -1 OFFSET ?
       )`,
      MAX_DELIVERIES_PER_SHARD,
    );
  }

  private prunePeerHistory(participantKey: string): void {
    this.ctx.storage.sql.exec(
      `DELETE FROM roster_peers
       WHERE rowid IN (
         SELECT rowid FROM roster_peers
         WHERE participant_key = ? AND active = 0
         ORDER BY joined_at DESC, provider_session_id DESC, peer_id DESC
         LIMIT -1 OFFSET ?
       )`,
      participantKey,
      MAX_INACTIVE_PEERS_PER_PARTICIPANT,
    );
  }

  private room(): RosterRoomRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterRoomRow>(
          "SELECT * FROM roster_room WHERE singleton = 1",
        )
        .toArray()[0] ?? null
    );
  }

  private bindingByParticipant(
    participantKey: string,
  ): RosterBindingRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterBindingRow>(
          "SELECT * FROM roster_bindings WHERE participant_key = ?",
          participantKey,
        )
        .toArray()[0] ?? null
    );
  }

  private bindingByPrincipal(principalId: string): RosterBindingRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterBindingRow>(
          "SELECT * FROM roster_bindings WHERE principal_id = ?",
          principalId,
        )
        .toArray()[0] ?? null
    );
  }

  private peer(
    providerSessionId: string,
    peerId: string,
  ): RosterPeerRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterPeerRow>(
          `SELECT * FROM roster_peers
           WHERE provider_session_id = ? AND peer_id = ?`,
          providerSessionId,
          peerId,
        )
        .toArray()[0] ?? null
    );
  }

  private activePeer(participantKey: string): RosterPeerRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterPeerRow>(
          `SELECT * FROM roster_peers
           WHERE participant_key = ? AND active = 1
           ORDER BY joined_at DESC
           LIMIT 1`,
          participantKey,
        )
        .toArray()[0] ?? null
    );
  }

  private latestPeer(participantKey: string): RosterPeerRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterPeerRow>(
          `SELECT * FROM roster_peers
           WHERE participant_key = ?
           ORDER BY joined_at DESC, provider_session_id DESC, peer_id DESC
           LIMIT 1`,
          participantKey,
        )
        .toArray()[0] ?? null
    );
  }

  private delivery(deliveryId: string): RosterDeliveryRow | null {
    return (
      this.ctx.storage.sql
        .exec<RosterDeliveryRow>(
          "SELECT digest FROM roster_deliveries WHERE delivery_id = ?",
          deliveryId,
        )
        .toArray()[0] ?? null
    );
  }
}

function matchesRoom(
  row: RosterRoomRow,
  room: RosterRoomIdentity,
): boolean {
  return (
    row.tenant_id === room.tenantId &&
    row.senti_session_id === room.sessionId &&
    row.room_epoch === room.roomEpoch &&
    row.room_id === room.roomId &&
    row.provider_meeting_id === room.providerMeetingId
  );
}

function validBinding(input: RosterBindingInput): boolean {
  return (
    Number.isInteger(input.shardIndex) &&
    input.shardIndex >= 0 &&
    PARTICIPANT_KEY.test(input.participantKey) &&
    PRINCIPAL_ID.test(input.principalId) &&
    OPAQUE_PROVIDER_ID.test(input.providerParticipantId) &&
    (input.kind === "human" || input.kind === "agent") &&
    (input.role === "moderator" ||
      input.role === "speaker" ||
      input.role === "listener") &&
    (input.displayName === null ||
      (input.displayName.length > 0 &&
        input.displayName.length <= 80)) &&
    Number.isFinite(Date.parse(input.now))
  );
}

function toRosterParticipant(row: RosterPageRow): RoomRosterParticipant {
  return {
    principalId: row.principal_id,
    providerParticipantId: row.provider_participant_id,
    providerCorrelationId: row.participant_key,
    providerSessionId: row.provider_session_id,
    providerPeerId: row.peer_id,
    kind: row.kind,
    role: row.role,
    displayName: row.display_name,
    joinedAt: row.joined_at,
  };
}

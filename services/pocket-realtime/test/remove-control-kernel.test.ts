import { env } from "cloudflare:workers";
import {
  reset,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  VoiceControlQueueEnvelope,
  WebhookEventSummary,
} from "../src/contracts";
import {
  executeRemoveKernel,
  type FreshVoiceControlAuthorizer,
  type PeerExactRemoveProvider,
  type RemoveKernelGovernor,
} from "../src/remove-control-kernel";
import type {
  ModerationExecutionReservation,
  ModerationReservationInput,
  RoomGovernor,
} from "../src/room-governor";

const TENANT_ID = "tenant-demo";
const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const ROOM_ID = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const PROVIDER_SESSION_ID = "05e57591-d89e-45c9-ae44-08dc1eaad0e0";
const TARGET_PARTICIPANT_KEY = "participant-target";
const TARGET_PEER_A = "peer-target-a";
const TARGET_PEER_B = "peer-target-b";
const NOW = "2026-07-29T11:00:00.000Z";

describe("remove-only execution and signed observation kernel", () => {
  beforeEach(async () => {
    await reset();
  });

  it("fails closed when authority is revoked between enqueue and execute", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    const provider = providerSpy({ disposition: "request_accepted" });

    const outcome = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer({ disposition: "denied" }),
      provider,
      NOW,
    );

    expect(outcome.disposition).toBe("conflict");
    expect(provider.ensureAbsent).not.toHaveBeenCalled();
    const command = await replay(setup);
    expect(command).toMatchObject({
      status: "conflict",
      resultCode: "VOICE_CONTROL_CONFLICT",
      providerRequestAccepted: false,
      providerStateObserved: false,
      causalityProven: false,
    });
    expect(command).not.toHaveProperty("providerMutationApplied");
  });

  it("reuses one attempt after an ambiguous crash and converges on an exact peer leave", async () => {
    const setup = await setupRemove();
    const firstReservation = await executionReservation(setup);
    const attemptIds: string[] = [];
    const crashProvider: PeerExactRemoveProvider = {
      async ensureAbsent(request) {
        attemptIds.push(request.attemptId);
        throw new Error("crash-after-provider-acceptance");
      },
    };
    await expect(
      executeRemoveKernel(
        firstReservation,
        kernelGovernor(setup.governor),
        authorizer(authorized()),
        crashProvider,
        NOW,
      ),
    ).rejects.toThrow("crash-after-provider-acceptance");

    const retryReservation = await executionReservation(setup);
    const retryProvider: PeerExactRemoveProvider = {
      async ensureAbsent(request) {
        attemptIds.push(request.attemptId);
        expect(request.targetPeerId).toBe(TARGET_PEER_A);
        expect(request.targetParticipantKey).toBe(TARGET_PARTICIPANT_KEY);
        return { disposition: "request_accepted" };
      },
    };
    const pending = await executeRemoveKernel(
      retryReservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      retryProvider,
      "2026-07-29T11:00:01.000Z",
    );
    expect(pending.disposition).toBe("pending_observation");
    expect(attemptIds).toHaveLength(2);
    expect(attemptIds[1]).toBe(attemptIds[0]);

    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantLeft",
      TARGET_PEER_A,
      "2026-07-29T11:00:02.000Z",
      "delivery-left-exact",
    );
    const command = await replay(setup);
    expect(command).toMatchObject({
      status: "desired_state_observed",
      resultCode: "REMOVE_LEAVE_OBSERVED",
      providerRequestAccepted: true,
      providerStateObserved: true,
      causalityProven: false,
    });
    expect(command).not.toHaveProperty("providerMutationApplied");
  });

  it("returns the exact observed terminal when the signed leave races provider acceptance", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    const provider: PeerExactRemoveProvider = {
      async ensureAbsent() {
        await acceptParticipantEvent(
          setup.governor,
          "meeting.participantLeft",
          TARGET_PEER_A,
          "2026-07-29T11:00:01.000Z",
          "delivery-left-during-provider-call",
        );
        return { disposition: "request_accepted" };
      },
    };
    const outcome = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      provider,
      NOW,
    );
    expect(outcome.disposition).toBe("desired_state_observed");
    expect(await replay(setup)).toMatchObject({
      status: "desired_state_observed",
      resultCode: "REMOVE_LEAVE_OBSERVED",
      providerStateObserved: true,
      causalityProven: false,
    });
  });

  it("keeps the newer peer active when a stale join arrives out of order", async () => {
    const setup = await setupRemove();
    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantJoined",
      TARGET_PEER_B,
      "2026-07-29T11:10:00.000Z",
      "delivery-join-b",
    );
    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantJoined",
      "peer-stale",
      "2026-07-29T11:05:00.000Z",
      "delivery-join-stale",
    );

    const active = (await setup.governor.debugPeerSnapshot()).filter(
      (peer) => peer.active,
    );
    expect(active).toHaveLength(1);
    expect(active[0]).toMatchObject({
      providerSessionId: PROVIDER_SESSION_ID,
      peerId: TARGET_PEER_B,
      participantKey: TARGET_PARTICIPANT_KEY,
    });

    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantLeft",
      TARGET_PEER_A,
      "2026-07-29T11:11:00.000Z",
      "delivery-late-left-a",
    );
    const afterOldLeave = (
      await setup.governor.debugPeerSnapshot()
    ).filter((peer) => peer.active);
    expect(afterOldLeave).toHaveLength(1);
    expect(afterOldLeave[0]?.peerId).toBe(TARGET_PEER_B);
    expect(await replay(setup)).toMatchObject({ status: "pending" });

    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantLeft",
      TARGET_PEER_B,
      "2026-07-29T11:12:00.000Z",
      "delivery-left-b",
    );
    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantJoined",
      "peer-stale",
      "2026-07-29T11:05:00.000Z",
      "delivery-stale-join-replay",
    );
    expect(
      (await setup.governor.debugPeerSnapshot()).filter(
        (peer) => peer.active,
      ),
    ).toHaveLength(0);
  });

  it("bounds inactive peer history without permitting an evicted stale join to resurrect", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer({ disposition: "denied" }),
      providerSpy({ disposition: "request_accepted" }),
      NOW,
    );

    for (let index = 1; index <= 8; index += 1) {
      const joinedAt = new Date(
        Date.parse("2026-07-29T11:00:00.000Z") +
          index * 60_000,
      ).toISOString();
      await acceptParticipantEvent(
        setup.governor,
        "meeting.participantJoined",
        `peer-churn-${index}`,
        joinedAt,
        `delivery-churn-join-${index}`,
      );
    }
    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantLeft",
      "peer-churn-8",
      "2026-07-29T11:09:00.000Z",
      "delivery-churn-left-final",
    );
    expect(await setup.governor.debugPeerSnapshot()).toHaveLength(4);

    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantJoined",
      "peer-churn-1",
      "2026-07-29T11:01:00.000Z",
      "delivery-churn-stale-replay",
    );
    const peers = await setup.governor.debugPeerSnapshot();
    expect(peers).toHaveLength(4);
    expect(peers.some((peer) => peer.active)).toBe(false);
  });

  it("does not let a leave predating the attempt satisfy the command", async () => {
    const setup = await setupRemove({
      joinedAt: "2026-07-29T10:00:00.000Z",
    });
    const reservation = await executionReservation(setup);
    const pending = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      providerSpy({ disposition: "request_accepted" }),
      NOW,
    );
    expect(pending.disposition).toBe("pending_observation");

    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantLeft",
      TARGET_PEER_A,
      "2026-07-29T10:59:59.999Z",
      "delivery-left-before-attempt",
    );
    expect(await replay(setup)).toMatchObject({
      status: "pending_observation",
      providerStateObserved: false,
      causalityProven: false,
    });
  });

  it("does not let a wrong session or peer observation satisfy the command, and deduplicates the exact leave", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    const pending = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      providerSpy({ disposition: "request_accepted" }),
      NOW,
    );
    expect(pending.disposition).toBe("pending_observation");

    const wrongSession = participantEvent(
      "meeting.participantLeft",
      TARGET_PEER_A,
      "2026-07-29T11:00:01.000Z",
      "delivery-wrong-session",
      "provider-session-wrong",
    );
    expect(
      (
        await setup.governor.acceptWebhook(
          wrongSession,
          wrongSession.occurredAt,
          10_000,
        )
      ).disposition,
    ).toBe("new");
    await setup.governor.markWebhookEnqueued(
      wrongSession.deliveryId,
      wrongSession.digest,
      wrongSession.occurredAt,
    );

    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantLeft",
      "peer-wrong",
      "2026-07-29T11:00:02.000Z",
      "delivery-wrong-peer",
    );
    expect(await replay(setup)).toMatchObject({
      status: "pending_observation",
      providerStateObserved: false,
    });

    const exact = participantEvent(
      "meeting.participantLeft",
      TARGET_PEER_A,
      "2026-07-29T11:00:03.000Z",
      "delivery-exact-deduped",
    );
    expect(
      (
        await setup.governor.acceptWebhook(
          exact,
          exact.occurredAt,
          10_000,
        )
      ).disposition,
    ).toBe("new");
    await setup.governor.markWebhookEnqueued(
      exact.deliveryId,
      exact.digest,
      exact.occurredAt,
    );
    expect(
      (
        await setup.governor.acceptWebhook(
          exact,
          "2026-07-29T11:00:04.000Z",
          10_000,
        )
      ).disposition,
    ).toBe("duplicate");
    expect(await replay(setup)).toMatchObject({
      status: "desired_state_observed",
      resultCode: "REMOVE_LEAVE_OBSERVED",
      providerStateObserved: true,
      causalityProven: false,
    });
  });

  it("rejects a concurrent remove for one peer but permits a later peer generation", async () => {
    const setup = await setupRemove();
    const second = await setup.governor.reserveModeration({
      ...setup.input,
      commandId: "command-remove-0002",
      idempotencyHash: "idempotency-remove-0002",
      payloadHash: "payload-remove-0002",
      expectedRevision: 1,
    });
    expect(second.disposition).toBe("target_busy");

    const reservation = await executionReservation(setup);
    await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer({ disposition: "denied" }),
      providerSpy({ disposition: "request_accepted" }),
      NOW,
    );
    await acceptParticipantEvent(
      setup.governor,
      "meeting.participantJoined",
      TARGET_PEER_B,
      "2026-07-29T11:10:00.000Z",
      "delivery-new-peer",
    );
    const later = await setup.governor.reserveModeration({
      ...setup.input,
      commandId: "command-remove-0003",
      idempotencyHash: "idempotency-remove-0003",
      payloadHash: "payload-remove-0003",
      expectedRevision: 1,
    });
    expect(later.disposition).toBe("accepted");
  });

  it("records already-absent as observed without claiming a request or causality", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    const outcome = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      providerSpy({ disposition: "already_absent" }),
      NOW,
    );
    expect(outcome.disposition).toBe("desired_state_observed");
    expect(await replay(setup)).toMatchObject({
      status: "desired_state_observed",
      resultCode: "REMOVE_ALREADY_ABSENT_OBSERVED",
      providerRequestAccepted: false,
      providerStateObserved: true,
      causalityProven: false,
    });
  });

  it("terminalizes a replacement-peer preflight mismatch without a mutation claim", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    let mutationCalls = 0;
    const provider: PeerExactRemoveProvider = {
      async ensureAbsent(request) {
        expect(request.targetPeerId).toBe(TARGET_PEER_A);
        // A real adapter performs its peer-generation preflight here. A
        // mismatch must return before its mutation primitive is reached.
        expect(mutationCalls).toBe(0);
        return { disposition: "peer_mismatch" };
      },
    };
    const outcome = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      provider,
      NOW,
    );
    expect(outcome.disposition).toBe("conflict");
    expect(mutationCalls).toBe(0);
    const command = await replay(setup);
    expect(command).toMatchObject({
      status: "conflict",
      resultCode: "VOICE_CONTROL_CONFLICT",
      providerRequestAccepted: false,
      providerStateObserved: false,
      causalityProven: false,
    });
    expect(command).not.toHaveProperty("providerMutationApplied");
  });

  it("rejects a stale execution fence before provider I/O", async () => {
    const setup = await setupRemove();
    const stale = await executionReservation(setup);
    await setup.governor.releaseModerationExecution(
      setup.input.commandId,
      stale.fence,
    );
    const current = await executionReservation(setup);
    expect(current.fence).not.toBe(stale.fence);
    const provider = providerSpy({ disposition: "request_accepted" });
    const outcome = await executeRemoveKernel(
      stale,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      provider,
      NOW,
    );
    expect(outcome.disposition).toBe("stale_fence");
    expect(provider.ensureAbsent).not.toHaveBeenCalled();
    expect(await replay(setup)).toMatchObject({
      status: "pending",
      providerRequestAccepted: false,
      providerStateObserved: false,
    });
  });

  it("defers unavailable or expired fresh authorization with zero provider I/O", async () => {
    for (const authorization of [
      { disposition: "unavailable" } as const,
      {
        disposition: "authorized",
        validUntil: "2026-07-29T10:59:59.999Z",
      } as const,
    ]) {
      await reset();
      const setup = await setupRemove();
      const reservation = await executionReservation(setup);
      const provider = providerSpy({ disposition: "request_accepted" });
      const outcome = await executeRemoveKernel(
        reservation,
        kernelGovernor(setup.governor),
        authorizer(authorization),
        provider,
        NOW,
      );
      expect([
        "authorization_unavailable",
        "authorization_expired",
      ]).toContain(outcome.disposition);
      expect(provider.ensureAbsent).not.toHaveBeenCalled();
      expect(await replay(setup)).toMatchObject({
        status: "pending",
        providerRequestAccepted: false,
        providerStateObserved: false,
      });
    }
  });

  it("terminalizes an unobserved attempted remove as conflict at the watchdog deadline", async () => {
    const setup = await setupRemove();
    const reservation = await executionReservation(setup);
    const pending = await executeRemoveKernel(
      reservation,
      kernelGovernor(setup.governor),
      authorizer(authorized()),
      providerSpy({ disposition: "request_accepted" }),
      NOW,
    );
    expect(pending.disposition).toBe("pending_observation");

    await runInDurableObject(setup.governor, async (_instance, state) => {
      state.storage.sql.exec(
        `UPDATE moderation_commands
         SET attempt_started_at = ?
         WHERE command_id = ?`,
        "2000-01-01T00:00:00.000Z",
        setup.input.commandId,
      );
    });
    expect(await runDurableObjectAlarm(setup.governor)).toBe(true);
    const command = await replay(setup);
    expect(command).toMatchObject({
      status: "conflict",
      resultCode: "VOICE_CONTROL_CONFLICT",
      providerRequestAccepted: true,
      providerStateObserved: false,
      causalityProven: false,
    });
    expect(command).not.toHaveProperty("providerMutationApplied");
  });
});

async function setupRemove(
  options: { joinedAt?: string } = {},
): Promise<{
  governor: DurableObjectStub<RoomGovernor>;
  input: ModerationReservationInput;
  envelope: VoiceControlQueueEnvelope;
}> {
  const governor = env.ROOMS.getByName(ROOM_ID);
  const provision = await governor.reserveProvision(
    TENANT_ID,
    SESSION_ID,
    EPOCH,
    ROOM_ID,
    "post-meeting",
    NOW,
    10_000,
  );
  if (provision.disposition !== "acquired") {
    throw new Error("Expected room provision reservation.");
  }
  await governor.completeProvision(provision.fence, MEETING_ID, NOW);
  await seedAdmission(
    governor,
    "participant-actor",
    "principal-actor",
    "owner",
    "moderator",
    "provider-actor",
  );
  await seedAdmission(
    governor,
    TARGET_PARTICIPANT_KEY,
    "principal-target",
    "contributor",
    "speaker",
    "provider-target",
  );
  await acceptParticipantEvent(
    governor,
    "meeting.participantJoined",
    TARGET_PEER_A,
    options.joinedAt ?? "2026-07-29T10:30:00.000Z",
    "delivery-initial-peer",
  );
  const input: ModerationReservationInput = {
    tenantId: TENANT_ID,
    sessionId: SESSION_ID,
    roomEpoch: EPOCH,
    roomId: ROOM_ID,
    actorPrincipalId: "principal-actor",
    actorMembershipRole: "owner",
    targetPrincipalId: "principal-target",
    action: "remove",
    commandId: "command-remove-0001",
    idempotencyHash: "idempotency-remove-0001",
    payloadHash: "payload-remove-0001",
    expectedRevision: 0,
    now: NOW,
    maxDailyRequests: 10_000,
  };
  const accepted = await governor.reserveModeration(input);
  if (accepted.disposition !== "accepted") {
    throw new Error(`Expected accepted remove, got ${accepted.disposition}.`);
  }
  return {
    governor,
    input,
    envelope: {
      schemaVersion: "senti.voice_control.command.v1",
      roomId: ROOM_ID,
      commandId: input.commandId,
      controlRevision: accepted.command.controlRevision,
    },
  };
}

async function seedAdmission(
  governor: DurableObjectStub<RoomGovernor>,
  participantKey: string,
  principalId: string,
  membershipRole: "owner" | "contributor",
  role: "moderator" | "speaker",
  providerParticipantId: string,
): Promise<void> {
  const reservation = await governor.reserveAdmission(
    participantKey,
    principalId,
    membershipRole,
    role,
    NOW,
    10_000,
  );
  if (reservation.disposition !== "create") {
    throw new Error("Expected admission creation.");
  }
  await governor.completeAdmission(
    participantKey,
    reservation.fence,
    providerParticipantId,
    NOW,
  );
}

async function executionReservation(
  setup: Awaited<ReturnType<typeof setupRemove>>,
): Promise<
  Extract<ModerationExecutionReservation, { disposition: "execute" }>
> {
  const reservation = await setup.governor.reserveModerationExecution(
    setup.envelope,
    NOW,
  );
  if (reservation.disposition !== "execute") {
    throw new Error(`Expected execution lease, got ${reservation.disposition}.`);
  }
  return reservation;
}

async function replay(
  setup: Awaited<ReturnType<typeof setupRemove>>,
) {
  const replayed = await setup.governor.reserveModeration(setup.input);
  if (replayed.disposition !== "replay") {
    throw new Error(`Expected replay, got ${replayed.disposition}.`);
  }
  return replayed.command;
}

async function acceptParticipantEvent(
  governor: DurableObjectStub<RoomGovernor>,
  eventName: "meeting.participantJoined" | "meeting.participantLeft",
  peerId: string,
  occurredAt: string,
  deliveryId: string,
): Promise<void> {
  const event = participantEvent(
    eventName,
    peerId,
    occurredAt,
    deliveryId,
  );
  const accepted = await governor.acceptWebhook(
    event,
    occurredAt,
    10_000,
  );
  expect(["new", "retry"]).toContain(accepted.disposition);
  await governor.markWebhookEnqueued(
    deliveryId,
    event.digest,
    occurredAt,
  );
}

function participantEvent(
  eventName: "meeting.participantJoined" | "meeting.participantLeft",
  peerId: string,
  occurredAt: string,
  deliveryId: string,
  providerSessionId = PROVIDER_SESSION_ID,
): WebhookEventSummary {
  return {
    deliveryId,
    digest: `digest-${deliveryId}`,
    eventName,
    providerMeetingId: MEETING_ID,
    providerSessionId,
    peerId,
    customParticipantId: TARGET_PARTICIPANT_KEY,
    participantJoinedAt:
      eventName === "meeting.participantJoined" ? occurredAt : null,
    participantLeftAt:
      eventName === "meeting.participantLeft" ? occurredAt : null,
    occurredAt,
  };
}

function kernelGovernor(
  governor: DurableObjectStub<RoomGovernor>,
): RemoveKernelGovernor {
  return governor as unknown as RemoveKernelGovernor;
}

function authorizer(
  result: Awaited<
    ReturnType<FreshVoiceControlAuthorizer["authorize"]>
  >,
): FreshVoiceControlAuthorizer {
  return {
    authorize: vi.fn(async () => result),
  };
}

function authorized() {
  return {
    disposition: "authorized" as const,
    validUntil: "2026-07-29T11:05:00.000Z",
  };
}

function providerSpy(
  result: Awaited<ReturnType<PeerExactRemoveProvider["ensureAbsent"]>>,
): PeerExactRemoveProvider & {
  ensureAbsent: ReturnType<typeof vi.fn>;
} {
  return {
    ensureAbsent: vi.fn(async () => result),
  };
}

import { env } from "cloudflare:workers";
import {
  createExecutionContext,
  createMessageBatch,
  getQueueResult,
  reset,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  VOICE_CONTROL_QUEUE_SCHEMA,
  type VoiceControlQueueEnvelope,
} from "../src/contracts";
import type { RuntimeEnv } from "../src/env";
import worker from "../src/index";
import { parseVoiceControlQueueEnvelope } from "../src/validation";

const TENANT_ID = "tenant-demo";
const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const ROOM_ID = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const NOW = new Date().toISOString();
const COMMAND_ID = "command-outbox-0001";

describe("voice-control alarm, outbox, and Queue boundary", () => {
  beforeEach(async () => {
    await reset();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("rolls back the alarm and SQL write together when the SQLite transaction aborts", async () => {
    const { governor } = await setupGovernor();

    await runInDurableObject(governor, async (_instance, state) => {
      let failed = false;
      try {
        await state.storage.transaction(async (txn) => {
          await txn.setAlarm(Date.now() + 60_000);
          state.storage.sql.exec(
            `INSERT INTO daily_usage (
               usage_day, control_requests, participant_ms, updated_at
             ) VALUES ('2099-01-01', 99, 0, '2099-01-01T00:00:00.000Z')`,
          );
          throw new Error("abort-after-alarm-and-sql");
        });
      } catch {
        failed = true;
      }
      expect(failed).toBe(true);
      expect(await state.storage.getAlarm()).toBeNull();
      expect(
        state.storage.sql
          .exec<{ count: number }>(
            "SELECT COUNT(*) AS count FROM daily_usage WHERE usage_day = '2099-01-01'",
          )
          .one().count,
      ).toBe(0);
    });
  });

  it("commits a wake-up with the intent and marks a bounded envelope only after send", async () => {
    const { governor, input } = await setupGovernor();
    const sent: VoiceControlQueueEnvelope[][] = [];
    const send = vi
      .spyOn(env.VOICE_CONTROL_QUEUE, "sendBatch")
      .mockImplementation(async (messages) => {
        sent.push(queueBodies(messages));
        return queueSendResponse();
      });

    const accepted = await governor.reserveModeration(input);
    expect(accepted.disposition).toBe("accepted");
    expect(
      await runInDurableObject(governor, async (_instance, state) =>
        state.storage.getAlarm(),
      ),
    ).not.toBeNull();
    expect(await governor.debugOutboxSnapshot()).toEqual([
      {
        commandId: COMMAND_ID,
        controlRevision: 1,
        state: "pending",
        dispatchAttempts: 0,
      },
    ]);

    expect(await runDurableObjectAlarm(governor)).toBe(true);
    expect(send).toHaveBeenCalledTimes(1);
    expect(sent).toEqual([
      [
        {
          schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
          roomId: ROOM_ID,
          commandId: COMMAND_ID,
          controlRevision: 1,
        },
      ],
    ]);
    expect(await governor.debugOutboxSnapshot()).toEqual([
      {
        commandId: COMMAND_ID,
        controlRevision: 1,
        state: "dispatched",
        dispatchAttempts: 1,
      },
    ]);
    expect(
      await runInDurableObject(governor, async (_instance, state) =>
        state.storage.getAlarm(),
      ),
    ).not.toBeNull();
  });

  it("keeps recovery armed and resends the identical envelope after an ambiguous send failure", async () => {
    const { governor, input } = await setupGovernor();
    const sent: VoiceControlQueueEnvelope[][] = [];
    let attempt = 0;
    vi.spyOn(env.VOICE_CONTROL_QUEUE, "sendBatch").mockImplementation(
      async (messages) => {
        sent.push(queueBodies(messages));
        attempt += 1;
        if (attempt === 1) {
          throw new Error("Outcome unknown after broker handoff.");
        }
        return queueSendResponse();
      },
    );

    expect((await governor.reserveModeration(input)).disposition).toBe(
      "accepted",
    );
    await expect(runDurableObjectAlarm(governor)).rejects.toThrow(
      "Voice-control outbox dispatch failed.",
    );
    expect(await governor.debugOutboxSnapshot()).toEqual([
      {
        commandId: COMMAND_ID,
        controlRevision: 1,
        state: "pending",
        dispatchAttempts: 1,
      },
    ]);
    expect(
      await runInDurableObject(governor, async (_instance, state) =>
        state.storage.getAlarm(),
      ),
    ).not.toBeNull();

    expect(await runDurableObjectAlarm(governor)).toBe(true);
    expect(sent).toHaveLength(2);
    expect(sent[1]).toEqual(sent[0]);
    expect(await governor.debugOutboxSnapshot()).toEqual([
      {
        commandId: COMMAND_ID,
        controlRevision: 1,
        state: "dispatched",
        dispatchAttempts: 2,
      },
    ]);
  });

  it("drains at most 32 commands per alarm and re-arms the remainder", async () => {
    const { governor } = await setupGovernor();
    await runInDurableObject(governor, async (_instance, state) => {
      state.storage.transactionSync(() => {
        for (let index = 1; index <= 33; index += 1) {
          const suffix = index.toString().padStart(4, "0");
          const commandId = `command-burst-${suffix}`;
          state.storage.sql.exec(
            `INSERT INTO moderation_commands (
               command_id, idempotency_hash, payload_hash,
               actor_principal_id, target_principal_id,
               target_participant_key, provider_participant_id, action,
               expected_revision, result_revision, state,
               execution_fence, execution_lease_until, result_code,
               provider_mutation_applied, created_at, finalized_at
             ) VALUES (
               ?, ?, ?, 'principal-actor', 'principal-target',
               'participant-target', 'provider-target', 'mute',
               ?, ?, 'pending', NULL, NULL, NULL, 0, ?, NULL
             )`,
            commandId,
            `idempotency-burst-${suffix}`,
            `payload-burst-${suffix}`,
            index - 1,
            index,
            NOW,
          );
          state.storage.sql.exec(
            `INSERT INTO moderation_outbox (
               command_id, room_id, result_revision, state,
               dispatch_attempts, last_attempt_at, dispatched_at
             ) VALUES (?, ?, ?, 'pending', 0, NULL, NULL)`,
            commandId,
            ROOM_ID,
            index,
          );
        }
        state.storage.sql.exec(
          "UPDATE room SET control_revision = 33 WHERE singleton = 1",
        );
      });
      await state.storage.setAlarm(Date.now() + 60_000);
    });
    const batchSizes: number[] = [];
    vi.spyOn(env.VOICE_CONTROL_QUEUE, "sendBatch").mockImplementation(
      async (messages) => {
        batchSizes.push(Array.from(messages).length);
        return queueSendResponse();
      },
    );

    expect(await runDurableObjectAlarm(governor)).toBe(true);
    expect(batchSizes).toEqual([32]);
    expect((await governor.debugSnapshot()).pendingOutboxCount).toBe(1);
    expect(
      await runInDurableObject(governor, async (_instance, state) =>
        state.storage.getAlarm(),
      ),
    ).not.toBeNull();

    expect(await runDurableObjectAlarm(governor)).toBe(true);
    expect(batchSizes).toEqual([32, 1]);
    expect((await governor.debugSnapshot()).pendingOutboxCount).toBe(0);
  });

  it("terminalizes a dispatched command when Queue and DLQ processing never finish", async () => {
    const { governor, input } = await setupGovernor();
    const send = vi
      .spyOn(env.VOICE_CONTROL_QUEUE, "sendBatch")
      .mockResolvedValue(queueSendResponse());
    expect((await governor.reserveModeration(input)).disposition).toBe(
      "accepted",
    );
    expect(await runDurableObjectAlarm(governor)).toBe(true);
    expect(send).toHaveBeenCalledTimes(1);

    await runInDurableObject(governor, async (_instance, state) => {
      state.storage.sql.exec(
        "UPDATE moderation_commands SET created_at = ? WHERE command_id = ?",
        "2000-01-01T00:00:00.000Z",
        COMMAND_ID,
      );
    });
    const providerFetch = vi.fn(async () => {
      throw new Error("Terminal reconciliation must not perform provider I/O.");
    });
    vi.stubGlobal("fetch", providerFetch);

    expect(await runDurableObjectAlarm(governor)).toBe(true);
    expect(send).toHaveBeenCalledTimes(1);
    const replay = await governor.reserveModeration(input);
    expect(replay.disposition).toBe("replay");
    if (replay.disposition !== "replay") {
      throw new Error("Expected reconciled terminal command replay.");
    }
    expect(replay.command).toMatchObject({
      status: "unsupported",
      resultCode: "queue_delivery_exhausted",
      providerMutationApplied: false,
    });
    expect((await governor.debugSnapshot()).pendingCommandCount).toBe(0);
    expect(providerFetch).not.toHaveBeenCalled();
  });

  it("acknowledges two copies with one terminal unsupported result and zero provider I/O", async () => {
    const { governor, input } = await setupGovernor();
    const sent: VoiceControlQueueEnvelope[][] = [];
    vi.spyOn(env.VOICE_CONTROL_QUEUE, "sendBatch").mockImplementation(
      async (messages) => {
        sent.push(queueBodies(messages));
        return queueSendResponse();
      },
    );
    expect((await governor.reserveModeration(input)).disposition).toBe(
      "accepted",
    );
    expect(await runDurableObjectAlarm(governor)).toBe(true);
    const envelope = sent[0]?.[0];
    if (!envelope) throw new Error("Expected one dispatched envelope.");

    const providerFetch = vi.fn(async () => {
      throw new Error("Provider I/O is forbidden in the safe outbox slice.");
    });
    vi.stubGlobal("fetch", providerFetch);
    const batch = createMessageBatch("senti-pocket-voice-control-v1", [
      queueMessage("delivery-one", envelope),
      queueMessage("delivery-two", envelope),
    ]);
    const ctx = createExecutionContext();
    await worker.queue(batch, queueEnvironment());
    const result = await getQueueResult(batch, ctx);

    expect(result.explicitAcks).toEqual(["delivery-one", "delivery-two"]);
    expect(result.retryMessages).toEqual([]);
    expect(providerFetch).not.toHaveBeenCalled();
    const replay = await governor.reserveModeration(input);
    expect(replay.disposition).toBe("replay");
    if (replay.disposition !== "replay") {
      throw new Error("Expected the original terminal command.");
    }
    expect(replay.command).toMatchObject({
      commandId: COMMAND_ID,
      controlRevision: 1,
      status: "unsupported",
      providerMutationApplied: false,
      resultCode: "executor_unavailable",
    });
    expect((await governor.debugSnapshot()).pendingCommandCount).toBe(0);
  });

  it("explicitly retries a leased command and acknowledges poison without touching state", async () => {
    const { governor, input } = await setupGovernor();
    const accepted = await governor.reserveModeration(input);
    if (accepted.disposition !== "accepted") {
      throw new Error("Expected accepted command intent.");
    }
    const envelope: VoiceControlQueueEnvelope = {
      schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
      roomId: ROOM_ID,
      commandId: COMMAND_ID,
      controlRevision: accepted.command.controlRevision,
    };
    expect(
      (
        await governor.reserveModerationExecution(
          envelope,
          new Date().toISOString(),
        )
      ).disposition,
    ).toBe("execute");

    const batch = createMessageBatch("senti-pocket-voice-control-v1", [
      queueMessage("delivery-busy", envelope),
      queueMessage("delivery-poison", {
        ...envelope,
        schemaVersion: "not-the-schema",
      }),
    ]);
    const ctx = createExecutionContext();
    await worker.queue(batch, queueEnvironment());
    const result = await getQueueResult(batch, ctx);

    expect(result.explicitAcks).toEqual(["delivery-poison"]);
    expect(result.retryMessages).toHaveLength(1);
    expect(result.retryMessages[0]).toMatchObject({
      msgId: "delivery-busy",
    });
    expect((await governor.debugSnapshot()).pendingCommandCount).toBe(1);
  });

  it("turns a valid DLQ envelope into one idempotent terminal non-mutation result", async () => {
    const { governor, input } = await setupGovernor();
    const accepted = await governor.reserveModeration(input);
    if (accepted.disposition !== "accepted") {
      throw new Error("Expected accepted command intent.");
    }
    const envelope: VoiceControlQueueEnvelope = {
      schemaVersion: VOICE_CONTROL_QUEUE_SCHEMA,
      roomId: ROOM_ID,
      commandId: COMMAND_ID,
      controlRevision: accepted.command.controlRevision,
    };
    const providerFetch = vi.fn(async () => {
      throw new Error("Provider I/O is forbidden in the DLQ terminal path.");
    });
    vi.stubGlobal("fetch", providerFetch);

    const firstBatch = createMessageBatch(
      "senti-pocket-voice-control-v1-dlq",
      [queueMessage("dead-letter-one", envelope)],
    );
    const firstContext = createExecutionContext();
    await worker.queue(firstBatch, queueEnvironment());
    const firstResult = await getQueueResult(firstBatch, firstContext);
    expect(firstResult.explicitAcks).toEqual(["dead-letter-one"]);

    const replay = await governor.reserveModeration(input);
    expect(replay.disposition).toBe("replay");
    if (replay.disposition !== "replay") {
      throw new Error("Expected terminal command replay.");
    }
    expect(replay.command).toMatchObject({
      status: "unsupported",
      resultCode: "queue_delivery_exhausted",
      providerMutationApplied: false,
    });

    const secondBatch = createMessageBatch(
      "senti-pocket-voice-control-v1-dlq",
      [queueMessage("dead-letter-two", envelope)],
    );
    const secondContext = createExecutionContext();
    await worker.queue(secondBatch, queueEnvironment());
    const secondResult = await getQueueResult(secondBatch, secondContext);
    expect(secondResult.explicitAcks).toEqual(["dead-letter-two"]);
    expect(providerFetch).not.toHaveBeenCalled();
  });
});

async function setupGovernor() {
  const governor = env.ROOMS.getByName(ROOM_ID);
  const provision = await governor.reserveProvision(
    TENANT_ID,
    SESSION_ID,
    EPOCH,
    ROOM_ID,
    "post-meeting",
    NOW,
    20,
  );
  if (provision.disposition !== "acquired") {
    throw new Error("Expected room provision reservation.");
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
      roomId: ROOM_ID,
      actorPrincipalId: "principal-actor",
      actorMembershipRole: "owner" as const,
      targetPrincipalId: "principal-target",
      action: "mute" as const,
      commandId: COMMAND_ID,
      idempotencyHash: "idempotency-hash-outbox-0001",
      payloadHash: "payload-hash-outbox-0001",
      expectedRevision: 0,
      now: NOW,
      maxDailyRequests: 20,
    },
  };
}

function queueBodies(
  messages: Iterable<MessageSendRequest<unknown>>,
): VoiceControlQueueEnvelope[] {
  return Array.from(messages, (message) =>
    parseVoiceControlQueueEnvelope(message.body),
  );
}

function queueSendResponse(): QueueSendBatchResponse {
  return {
    metadata: {
      metrics: {
        backlogCount: 0,
        backlogBytes: 0,
      },
    },
  };
}

function queueMessage(
  id: string,
  body: unknown,
) {
  return {
    id,
    timestamp: new Date(NOW),
    attempts: 1,
    body,
  };
}

function queueEnvironment(): RuntimeEnv {
  return {
    ...env,
    CLOUDFLARE_API_TOKEN: "not-used-by-voice-control-queue-tests",
    ROOM_KEY_HMAC_SECRET:
      "not-used-room-secret-at-least-thirty-two-characters",
    IDENTITY_HMAC_SECRET:
      "not-used-identity-secret-at-least-thirty-two-characters",
  };
}

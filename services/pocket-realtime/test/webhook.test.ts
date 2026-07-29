import { env } from "cloudflare:workers";
import {
  createExecutionContext,
  reset,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { TranscriptQueueEnvelope } from "../src/contracts";
import type { RuntimeEnv } from "../src/env";
import { deriveRoomId, meetingTitle } from "../src/identity";

const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const TENANT_ID = "tenant-demo";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const ACCOUNT_ID = "023e105f4ecef8ad9ca31a8372d0c353";
const APP_ID = "6f80f956-3195-489a-aa76-9f26d3234160";
const ROOM_SECRET = "room-key-test-secret-at-least-thirty-two-characters";

describe("RealtimeKit signed webhook intake", () => {
  let keyPair: CryptoKeyPair;
  let publicKeyPem: string;
  let roomId: string;
  let queue: TranscriptQueueEnvelope[];
  let queueFailuresRemaining: number;
  let testEnv: RuntimeEnv;

  beforeAll(async () => {
    keyPair = (await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"],
    )) as CryptoKeyPair;
    publicKeyPem = toPem(await crypto.subtle.exportKey("spki", keyPair.publicKey));
    roomId = await deriveRoomId(ROOM_SECRET, TENANT_ID, SESSION_ID, EPOCH);
  });

  beforeEach(async () => {
    await reset();
    queue = [];
    queueFailuresRemaining = 0;
    testEnv = environment(queue);
    const governor = testEnv.ROOMS.getByName(roomId);
    const now = new Date().toISOString();
    const reservation = await governor.reserveProvision(
      TENANT_ID,
      SESSION_ID,
      EPOCH,
      roomId,
      "post-meeting",
      now,
      10_000,
    );
    if (reservation.disposition !== "acquired") throw new Error("Failed to seed room.");
    await governor.completeProvision(reservation.fence, MEETING_ID, now);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const request = new Request(input);
        if (new URL(request.url).hostname === "keys.cloudflare.test") {
          return Response.json({
            success: true,
            data: { publicKey: publicKeyPem },
          });
        }
        throw new Error(`Unexpected fetch: ${request.url}`);
      }),
    );
  });

  afterAll(() => {
    vi.unstubAllGlobals();
  });

  it("accepts once, queues only the bounded transcript reference, and deduplicates replay", async () => {
    const body = transcriptBody();
    const first = await postSigned(body, "delivery-transcript-0001");
    expect(first.status).toBe(202);
    expect(await first.json()).toMatchObject({ disposition: "new" });
    expect(queue).toHaveLength(1);
    expect(queue[0]).toMatchObject({
      schema: "senti.realtimekit_webhook.v1",
      tenantId: TENANT_ID,
      sessionId: SESSION_ID,
      roomEpoch: EPOCH,
      roomId,
      providerMeetingId: MEETING_ID,
      providerSessionId: "05e57591-d89e-45c9-ae44-08dc1eaad0e0",
      deliveryId: "delivery-transcript-0001",
      eventName: "meeting.transcript",
    });
    expect(JSON.stringify(queue[0])).not.toContain("download.cloudflare.test");
    expect(JSON.stringify(queue[0])).not.toContain("transcriptDownloadUrl");

    const duplicate = await postSigned(body, "delivery-transcript-0001");
    expect(duplicate.status).toBe(202);
    expect(await duplicate.json()).toMatchObject({ disposition: "duplicate" });
    expect(queue).toHaveLength(1);

    const snapshot = await testEnv.ROOMS.getByName(roomId).debugSnapshot();
    expect(snapshot.deliveryCount).toBe(1);
    expect(snapshot.transcriptBodyColumns).toBe(0);
  });

  it("rejects a tampered body before parsing or durable writes", async () => {
    const original = JSON.stringify(transcriptBody());
    const signature = await sign(original);
    const tampered = original.replace("transcript.json", "attacker.json");
    const response = await invokeWebhook(tampered, signature, "delivery-tamper-0001");
    expect(response.status).toBe(401);

    const snapshot = await testEnv.ROOMS.getByName(roomId).debugSnapshot();
    expect(snapshot.deliveryCount).toBe(0);
    expect(queue).toHaveLength(0);
  });

  it("rejects a validly signed delivery-id collision with different content", async () => {
    const first = await postSigned(transcriptBody(), "delivery-conflict-0001");
    expect(first.status).toBe(202);

    const changed = {
      ...transcriptBody(),
      transcriptDownloadUrl: "https://download.cloudflare.test/other.json",
    };
    const collision = await postSigned(changed, "delivery-conflict-0001");
    expect(collision.status).toBe(409);
    expect(await collision.json()).toMatchObject({
      error: { code: "VOICE_CONTROL_CONFLICT", recoverable: true },
    });
    expect(queue).toHaveLength(1);
  });

  it("rejects a transcript without a provider session before durable writes", async () => {
    const body = transcriptBody();
    body.meeting = {
      ...(body.meeting as Record<string, unknown>),
      sessionId: undefined,
    };
    const response = await postSigned(body, "delivery-no-session-0001");
    expect(response.status).toBe(422);
    expect(await response.json()).toMatchObject({
      error: { code: "VOICE_BAD_REQUEST", recoverable: false },
    });
    expect((await testEnv.ROOMS.getByName(roomId).debugSnapshot()).deliveryCount).toBe(0);
    expect(queue).toHaveLength(0);
  });

  it("retries one pending transcript after a queue failure and then deduplicates", async () => {
    queueFailuresRemaining = 1;
    const body = transcriptBody();

    const failed = await postSigned(body, "delivery-queue-retry-0001");
    expect(failed.status).toBe(503);
    expect(await failed.json()).toMatchObject({
      error: { code: "VOICE_TRANSCRIPT_DEGRADED", recoverable: true },
    });
    expect(queue).toHaveLength(0);

    const retried = await postSigned(body, "delivery-queue-retry-0001");
    expect(retried.status).toBe(202);
    expect(await retried.json()).toMatchObject({ disposition: "retry" });
    expect(queue).toHaveLength(1);

    const duplicate = await postSigned(body, "delivery-queue-retry-0001");
    expect(duplicate.status).toBe(202);
    expect(await duplicate.json()).toMatchObject({ disposition: "duplicate" });
    expect(queue).toHaveLength(1);
  });

  it("meters completed participant presence without presenting it as billing truth", async () => {
    const participant = {
      peerId: "peer-001",
      customParticipantId: "senti_test-participant",
      joinedAt: "2026-07-29T07:44:00.000Z",
    };
    const joined = await postSigned(
      {
        event: "meeting.participantJoined",
        meeting: {
          id: MEETING_ID,
          title: meetingTitle(roomId),
          sessionId: "05e57591-d89e-45c9-ae44-08dc1eaad0e0",
        },
        participant,
      },
      "delivery-joined-0001",
    );
    expect(joined.status).toBe(202);

    const left = await postSigned(
      {
        event: "meeting.participantLeft",
        meeting: {
          id: MEETING_ID,
          title: meetingTitle(roomId),
          sessionId: "05e57591-d89e-45c9-ae44-08dc1eaad0e0",
        },
        participant: {
          ...participant,
          leftAt: "2026-07-29T07:45:00.000Z",
        },
      },
      "delivery-left-0001",
    );
    expect(left.status).toBe(202);

    const usage = await testEnv.ROOMS.getByName(roomId).usageSnapshot(
      new Date().toISOString(),
      10_000,
      836.36,
    );
    expect(usage.disposition).toBe("ok");
    if (usage.disposition !== "ok") throw new Error("Expected usage.");
    expect(usage.usage.completedParticipantMs).toBe(60_000);
    expect(usage.usage.transcriptionNeuronsEstimate).toBeCloseTo(836.36);
    expect(usage.usage.billingTruth).toBe(false);
    expect(queue).toHaveLength(0);
  });

  async function postSigned(body: unknown, deliveryId: string): Promise<Response> {
    const text = JSON.stringify(body);
    return invokeWebhook(text, await sign(text), deliveryId);
  }

  async function invokeWebhook(
    body: string,
    signature: string,
    deliveryId: string,
  ): Promise<Response> {
    const ctx = createExecutionContext();
    const response = await worker.fetch(
      new Request("https://worker.test/v1/realtimekit/webhooks", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "rtk-signature": signature,
          "rtk-uuid": deliveryId,
          "rtk-webhook-id": "webhook-test-0001",
        },
        body,
      }) as never,
      testEnv,
      ctx,
    );
    await waitOnExecutionContext(ctx);
    return response;
  }

  async function sign(body: string): Promise<string> {
    const signature = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      keyPair.privateKey,
      new TextEncoder().encode(body),
    );
    return base64(new Uint8Array(signature));
  }

  function transcriptBody(): Record<string, unknown> {
    return {
      event: "meeting.transcript",
      meeting: {
        id: MEETING_ID,
        title: meetingTitle(roomId),
        sessionId: "05e57591-d89e-45c9-ae44-08dc1eaad0e0",
        endedAt: "2026-07-29T07:45:00.000Z",
      },
      transcriptDownloadUrl: "https://download.cloudflare.test/transcript.json",
      transcriptDownloadUrlExpiry: "2026-08-05T07:45:00.000Z",
    };
  }

  function environment(messages: TranscriptQueueEnvelope[]): RuntimeEnv {
    return {
      ...(env as unknown as RuntimeEnv),
      SENTI_API_BASE_URL: "https://senti.test",
      REALTIMEKIT_API_BASE_URL: "https://api.cloudflare.test/client/v4",
      REALTIMEKIT_ACCOUNT_ID: ACCOUNT_ID,
      REALTIMEKIT_APP_ID: APP_ID,
      REALTIMEKIT_PRESET_MODERATOR: "senti-moderator",
      REALTIMEKIT_PRESET_SPEAKER: "senti-speaker",
      REALTIMEKIT_PRESET_LISTENER: "senti-listener",
      REALTIMEKIT_WEBHOOK_PUBLIC_KEY_URL: "https://keys.cloudflare.test/webhooks.json",
      TRANSCRIPTION_MODE: "post-meeting",
      TRANSCRIPTION_NEURONS_PER_AUDIO_MINUTE: "836.36",
      OUTBOUND_TIMEOUT_MS: "5000",
      MAX_CONTROL_REQUESTS_PER_ROOM_PER_DAY: "10000",
      CLOUDFLARE_API_TOKEN: "cloudflare-test-token-never-client-visible",
      ROOM_KEY_HMAC_SECRET: ROOM_SECRET,
      IDENTITY_HMAC_SECRET: "identity-test-secret-at-least-thirty-two-characters",
      TRANSCRIPT_INGEST_QUEUE: {
        async send(message: TranscriptQueueEnvelope): Promise<void> {
          if (queueFailuresRemaining > 0) {
            queueFailuresRemaining -= 1;
            throw new Error("injected queue failure");
          }
          messages.push(message);
        },
      } as unknown as Queue<TranscriptQueueEnvelope>,
    };
  }
});

function toPem(spki: ArrayBuffer): string {
  const encoded = base64(new Uint8Array(spki));
  return `-----BEGIN PUBLIC KEY-----\n${encoded.match(/.{1,64}/g)?.join("\n")}\n-----END PUBLIC KEY-----`;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

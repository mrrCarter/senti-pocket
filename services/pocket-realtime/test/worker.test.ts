import { env } from "cloudflare:workers";
import {
  createExecutionContext,
  reset,
  waitOnExecutionContext,
} from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";
import type { TranscriptQueueEnvelope } from "../src/contracts";
import type { RuntimeEnv } from "../src/env";

const SESSION_ID = "6cf7e861-546a-4b9f-b937-39182a5bd395";
const TENANT_ID = "tenant-demo";
const EPOCH = "5a73635c-cbd2-4e22-b24e-9a31520a939c";
const MEETING_ID = "bbb8940e-1b97-402a-97d6-2708b7feca41";
const PARTICIPANT_ID = "e32fb785-ddd0-4b96-b577-879327c0082f";
const ACCOUNT_ID = "023e105f4ecef8ad9ca31a8372d0c353";
const APP_ID = "6f80f956-3195-489a-aa76-9f26d3234160";
const BEARER = "senti-test-bearer-token-123456789";

interface ProviderCall {
  url: string;
  method: string;
  authorization: string | null;
  body: string;
}

describe("voice room control plane", () => {
  let membershipRole: "owner" | "viewer";
  let includeTenantIdentity: boolean;
  let providerCalls: ProviderCall[];
  let queueMessages: TranscriptQueueEnvelope[];
  let testEnv: RuntimeEnv;

  beforeEach(async () => {
    await reset();
    membershipRole = "owner";
    includeTenantIdentity = true;
    providerCalls = [];
    queueMessages = [];
    testEnv = environment(queueMessages);
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const request = new Request(input, init);
        const url = new URL(request.url);
        if (url.pathname === "/api/v1/auth/me") {
          return Response.json({ id: "human-carter", githubUsername: "mrrCarter" });
        }
        if (url.pathname === `/api/v1/sessions/${SESSION_ID}`) {
          return Response.json({
            session: {
              id: SESSION_ID,
              ...(includeTenantIdentity ? { tenantId: TENANT_ID } : {}),
              membershipRole,
            },
          });
        }
        if (url.hostname === "api.cloudflare.test") {
          const body = await request.text();
          providerCalls.push({
            url: request.url,
            method: request.method,
            authorization: request.headers.get("authorization"),
            body,
          });
          if (url.pathname.endsWith("/participants")) {
            return Response.json({
              success: true,
              data: {
                id: PARTICIPANT_ID,
                token: "short-lived-provider-token",
              },
            });
          }
          if (url.pathname.endsWith("/token")) {
            return Response.json({
              success: true,
              data: { token: "refreshed-provider-token" },
            });
          }
          if (url.pathname.includes("/participants/")) {
            return Response.json({
              success: true,
              data: { id: PARTICIPANT_ID },
            });
          }
          if (request.method === "POST") {
            return Response.json({
              success: true,
              data: { id: MEETING_ID },
            });
          }
          return Response.json({ success: true, data: { id: MEETING_ID } });
        }
        throw new Error(`Unexpected fetch: ${request.url}`);
      }),
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("opens a room, derives viewer role server-side, and refreshes repeat joins", async () => {
    const opened = await invoke(
      testEnv,
      "/v1/voice-rooms/open",
      openBody(),
    );
    expect(opened.status).toBe(201);
    const openPayload = await opened.json<{
      room: {
        roomId: string;
        requiredAgentMediaMode: string;
        agentMediaStatus: string;
        degradedAgentFallback: string;
        transcriptMode: string;
      };
    }>();
    expect(openPayload.room.roomId).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(openPayload.room.requiredAgentMediaMode).toBe("shared-room-track");
    expect(openPayload.room.agentMediaStatus).toBe("unsupported-pending-spike");
    expect(openPayload.room.degradedAgentFallback).toBe("edge-text-client-tts");
    expect(openPayload.room.transcriptMode).toBe("post-meeting");

    const createCall = providerCalls.find(
      (call) => call.method === "POST" && call.url.endsWith("/meetings"),
    );
    expect(createCall?.authorization).toBe("Bearer cloudflare-test-token-never-client-visible");
    expect(createCall?.body).toContain('"transcribe_on_end":true');
    expect(createCall?.body).not.toContain(SESSION_ID);

    membershipRole = "viewer";
    const joined = await invoke(testEnv, "/v1/voice-rooms/join", joinBody("moderator"));
    expect(joined.status).toBe(200);
    const joinedPayload = await joined.json<{
      credential: {
        role: string;
        authToken: string;
        clientDiscardAfter: string;
        providerScope: string;
        providerExpiry: string;
      };
    }>();
    expect(joinedPayload.credential.role).toBe("listener");
    expect(joinedPayload.credential.authToken).toBe("short-lived-provider-token");
    expect(Date.parse(joinedPayload.credential.clientDiscardAfter)).toBeGreaterThan(Date.now());
    expect(joinedPayload.credential.providerScope).toBe(
      "single-participant-single-meeting",
    );
    expect(joinedPayload.credential.providerExpiry).toBe(
      "time-bound-undisclosed",
    );
    expect(JSON.stringify(joinedPayload)).not.toContain(
      "cloudflare-test-token-never-client-visible",
    );

    const addCall = providerCalls.find((call) => call.url.endsWith("/participants"));
    expect(addCall?.body).toContain('"preset_name":"senti-listener"');
    expect(addCall?.body).not.toContain("human-carter");
    expect(addCall?.body).not.toContain(BEARER);

    const repeated = await invoke(testEnv, "/v1/voice-rooms/join", joinBody());
    expect(repeated.status).toBe(200);
    const repeatedPayload = await repeated.json<{
      credential: { authToken: string };
    }>();
    expect(repeatedPayload.credential.authToken).toBe("refreshed-provider-token");
    expect(providerCalls.filter((call) => call.url.endsWith("/participants"))).toHaveLength(1);
    expect(providerCalls.filter((call) => call.url.endsWith("/token"))).toHaveLength(1);
    expect(queueMessages).toHaveLength(0);
  });

  it("fails closed when paid transcription was not explicitly enabled", async () => {
    testEnv = { ...testEnv, TRANSCRIPTION_MODE: "disabled" };
    const response = await invoke(testEnv, "/v1/voice-rooms/open", openBody());
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: { code: "VOICE_PROVIDER_UNAVAILABLE", recoverable: true },
    });
    expect(providerCalls).toHaveLength(0);
  });

  it("does not let a viewer open a room", async () => {
    membershipRole = "viewer";
    const response = await invoke(testEnv, "/v1/voice-rooms/open", openBody());
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({
      error: { code: "VOICE_JOIN_NOT_AUTHORIZED", recoverable: false },
    });
    expect(providerCalls).toHaveLength(0);
  });

  it("fails closed when Senti does not expose the server-owned tenant identity", async () => {
    includeTenantIdentity = false;
    const response = await invoke(testEnv, "/v1/voice-rooms/open", openBody());
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: { code: "VOICE_PROVIDER_UNAVAILABLE", recoverable: true },
    });
    expect(providerCalls).toHaveLength(0);
  });

  it("rejects conflicting transport and body request identifiers before outbound work", async () => {
    const response = await invoke(
      testEnv,
      "/v1/voice-rooms/open",
      openBody(),
      { "x-request-id": "request-header-0001" },
    );
    expect(response.status).toBe(422);
    expect(response.headers.get("x-request-id")).toBe("request-header-0001");
    expect(await response.json()).toMatchObject({
      error: {
        code: "VOICE_BAD_REQUEST",
        requestId: "request-header-0001",
        recoverable: false,
      },
    });
    expect(providerCalls).toHaveLength(0);
  });

  it("rejects a non-UUID RealtimeKit App ID before provider I/O", async () => {
    testEnv = { ...testEnv, REALTIMEKIT_APP_ID: "not-a-realtimekit-uuid" };
    const response = await invoke(testEnv, "/v1/voice-rooms/open", openBody());
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({
      error: { code: "VOICE_PROVIDER_UNAVAILABLE", recoverable: true },
    });
    expect(providerCalls).toHaveLength(0);
  });

  function environment(queue: TranscriptQueueEnvelope[]): RuntimeEnv {
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
      ROOM_KEY_HMAC_SECRET: "room-key-test-secret-at-least-thirty-two-characters",
      IDENTITY_HMAC_SECRET: "identity-test-secret-at-least-thirty-two-characters",
      TRANSCRIPT_INGEST_QUEUE: {
        async send(message: TranscriptQueueEnvelope): Promise<void> {
          queue.push(message);
        },
      } as unknown as Queue<TranscriptQueueEnvelope>,
    };
  }
});

async function invoke(
  envValue: RuntimeEnv,
  path: string,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<Response> {
  const ctx = createExecutionContext();
  const response = await worker.fetch(
    new Request(`https://worker.test${path}`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${BEARER}`,
        "content-type": "application/json",
        ...headers,
      },
      body: JSON.stringify(body),
    }) as never,
    envValue,
    ctx,
  );
  await waitOnExecutionContext(ctx);
  return response;
}

function openBody(): Record<string, string> {
  return {
    sessionId: SESSION_ID,
    roomEpoch: EPOCH,
    transcriptConsent: "granted",
    requestId: "request-open-0001",
  };
}

function joinBody(requestedRole?: string): Record<string, string> {
  return {
    sessionId: SESSION_ID,
    roomEpoch: EPOCH,
    requestId: `request-join-${requestedRole ?? "default"}-0001`,
    ...(requestedRole ? { requestedRole } : {}),
  };
}

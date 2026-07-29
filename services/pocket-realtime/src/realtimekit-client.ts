import type { VoiceRole } from "./contracts";
import type { RuntimeEnv } from "./env";
import { upstreamError } from "./errors";
import { configuredPositiveInteger } from "./validation";

interface ProviderParticipant {
  id: string;
  token: string;
}

interface ProviderResponse {
  success?: unknown;
  data?: unknown;
}

export async function createMeeting(
  env: RuntimeEnv,
  title: string,
): Promise<{ id: string }> {
  const data = await providerRequest(env, meetingsPath(env), {
    method: "POST",
    body: JSON.stringify({
      title,
      status: "ACTIVE",
      session_keep_alive_time_in_secs: 60,
      record_on_start: false,
      persist_chat: false,
      transcribe_on_end: true,
      summarize_on_end: false,
      ai_config: {
        transcription: {
          language: "en-US",
          profanity_filter: false,
        },
      },
    }),
  });
  const id = stringField(data, "id");
  return { id };
}

export async function deactivateMeeting(env: RuntimeEnv, meetingId: string): Promise<void> {
  await providerRequest(env, `${meetingsPath(env)}/${encodeURIComponent(meetingId)}`, {
    method: "PATCH",
    body: JSON.stringify({ status: "INACTIVE" }),
  });
}

export async function addParticipant(
  env: RuntimeEnv,
  meetingId: string,
  customParticipantId: string,
  displayName: string,
  role: VoiceRole,
): Promise<ProviderParticipant> {
  const data = await providerRequest(
    env,
    `${meetingsPath(env)}/${encodeURIComponent(meetingId)}/participants`,
    {
      method: "POST",
      body: JSON.stringify({
        custom_participant_id: customParticipantId,
        preset_name: presetFor(env, role),
        name: displayName,
      }),
    },
  );
  return participant(data);
}

export async function updateParticipantRoleAndRefresh(
  env: RuntimeEnv,
  meetingId: string,
  participantId: string,
  displayName: string,
  role: VoiceRole,
): Promise<ProviderParticipant> {
  const participantPath = `${meetingsPath(env)}/${encodeURIComponent(
    meetingId,
  )}/participants/${encodeURIComponent(participantId)}`;
  await providerRequest(env, participantPath, {
    method: "PATCH",
    body: JSON.stringify({
      preset_name: presetFor(env, role),
      name: displayName,
    }),
  });
  const data = await providerRequest(env, `${participantPath}/token`, {
    method: "POST",
    body: JSON.stringify({}),
  });
  const refreshed = participant(data, participantId);
  return refreshed;
}

export async function refreshParticipant(
  env: RuntimeEnv,
  meetingId: string,
  participantId: string,
): Promise<ProviderParticipant> {
  const data = await providerRequest(
    env,
    `${meetingsPath(env)}/${encodeURIComponent(
      meetingId,
    )}/participants/${encodeURIComponent(participantId)}/token`,
    {
      method: "POST",
      body: JSON.stringify({}),
    },
  );
  return participant(data, participantId);
}

function meetingsPath(env: RuntimeEnv): string {
  requireConfiguration(env);
  return `/accounts/${encodeURIComponent(env.REALTIMEKIT_ACCOUNT_ID)}/realtime/kit/${encodeURIComponent(
    env.REALTIMEKIT_APP_ID,
  )}/meetings`;
}

async function providerRequest(
  env: RuntimeEnv,
  path: string,
  init: RequestInit,
): Promise<Record<string, unknown>> {
  requireConfiguration(env);
  const base = normalizedProviderBaseUrl(env.REALTIMEKIT_API_BASE_URL);
  const timeoutMs = configuredPositiveInteger(
    env.OUTBOUND_TIMEOUT_MS,
    30_000,
    "OUTBOUND_TIMEOUT_MS",
  );
  let response: Response;
  try {
    response = await fetch(`${base}${path}`, {
      ...init,
      headers: {
        authorization: `Bearer ${env.CLOUDFLARE_API_TOKEN}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch {
    throw upstreamError("realtimekit_unavailable", "RealtimeKit is unavailable.");
  }
  const body = await boundedJson(response);
  const envelope = asRecord(body);
  if (!response.ok || envelope.success !== true) {
    throw upstreamError("realtimekit_rejected", "RealtimeKit rejected the operation.");
  }
  return asRecord(envelope.data);
}

function requireConfiguration(env: RuntimeEnv): void {
  if (
    !/^[0-9a-f]{32}$/i.test(env.REALTIMEKIT_ACCOUNT_ID) ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
      env.REALTIMEKIT_APP_ID,
    ) ||
    !env.CLOUDFLARE_API_TOKEN ||
    env.CLOUDFLARE_API_TOKEN.length < 16
  ) {
    throw upstreamError(
      "realtimekit_not_configured",
      "RealtimeKit credentials are not configured.",
    );
  }
}

function normalizedProviderBaseUrl(value: string): string {
  try {
    const url = new URL(value);
    const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
    if (url.protocol !== "https:" && !(local && url.protocol === "http:")) {
      throw new Error();
    }
    if (url.username || url.password || url.search || url.hash) throw new Error();
    return url.toString().replace(/\/+$/, "");
  } catch {
    throw upstreamError(
      "invalid_realtimekit_configuration",
      "RealtimeKit API configuration is invalid.",
    );
  }
}

function presetFor(env: RuntimeEnv, role: VoiceRole): string {
  const preset =
    role === "moderator"
      ? env.REALTIMEKIT_PRESET_MODERATOR
      : role === "speaker"
        ? env.REALTIMEKIT_PRESET_SPEAKER
        : env.REALTIMEKIT_PRESET_LISTENER;
  if (!/^[A-Za-z0-9][A-Za-z0-9._ -]{1,127}$/.test(preset)) {
    throw upstreamError("invalid_preset_configuration", "RealtimeKit preset is invalid.");
  }
  return preset;
}

async function boundedJson(response: Response): Promise<unknown> {
  const bytes = await response.arrayBuffer();
  if (bytes.byteLength > 128 * 1024) {
    throw upstreamError("invalid_realtimekit_response", "RealtimeKit returned an invalid response.");
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw upstreamError("invalid_realtimekit_response", "RealtimeKit returned an invalid response.");
  }
}

function participant(data: Record<string, unknown>, fallbackId?: string): ProviderParticipant {
  const id = optionalStringField(data, "id") ?? fallbackId;
  const token = optionalStringField(data, "token");
  if (!id || !token) {
    throw upstreamError("invalid_realtimekit_response", "RealtimeKit returned an invalid participant.");
  }
  return { id, token };
}

function stringField(data: Record<string, unknown>, field: string): string {
  const value = optionalStringField(data, field);
  if (!value) {
    throw upstreamError("invalid_realtimekit_response", "RealtimeKit returned an invalid response.");
  }
  return value;
}

function optionalStringField(data: Record<string, unknown>, field: string): string | null {
  const value = data[field];
  return typeof value === "string" && value.length > 0 && value.length <= 8_192 ? value : null;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw upstreamError("invalid_realtimekit_response", "RealtimeKit returned an invalid response.");
  }
  return value as Record<string, unknown>;
}

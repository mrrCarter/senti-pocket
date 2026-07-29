import type {
  AuthenticatedMember,
  SentiMembershipRole,
} from "./contracts";
import type { RuntimeEnv } from "./env";
import { HttpError, upstreamError } from "./errors";
import { configuredPositiveInteger } from "./validation";

const MEMBERSHIP_ROLES = new Set<SentiMembershipRole>([
  "owner",
  "admin",
  "contributor",
  "viewer",
]);

export async function authenticateMember(
  request: Request,
  sessionId: string,
  env: RuntimeEnv,
): Promise<AuthenticatedMember> {
  const bearer = bearerFrom(request);
  const baseUrl = normalizedBaseUrl(env.SENTI_API_BASE_URL);
  const timeoutMs = configuredPositiveInteger(
    env.OUTBOUND_TIMEOUT_MS,
    30_000,
    "OUTBOUND_TIMEOUT_MS",
  );
  const headers = {
    authorization: `Bearer ${bearer}`,
    accept: "application/json",
    "x-request-id": crypto.randomUUID(),
  };

  let userResponse: Response;
  let sessionResponse: Response;
  try {
    [userResponse, sessionResponse] = await Promise.all([
      fetch(`${baseUrl}/api/v1/auth/me`, {
        method: "GET",
        headers,
        signal: AbortSignal.timeout(timeoutMs),
      }),
      fetch(`${baseUrl}/api/v1/sessions/${encodeURIComponent(sessionId)}`, {
        method: "GET",
        headers,
        signal: AbortSignal.timeout(timeoutMs),
      }),
    ]);
  } catch {
    throw upstreamError("senti_unavailable", "Senti membership verification is unavailable.");
  }

  if (userResponse.status === 401 || userResponse.status === 403) {
    throw new HttpError(401, "unauthorized", "A valid Senti bearer is required.");
  }
  if (sessionResponse.status === 401) {
    throw new HttpError(401, "unauthorized", "A valid Senti bearer is required.");
  }
  if (sessionResponse.status === 403 || sessionResponse.status === 404) {
    throw new HttpError(403, "not_a_session_member", "Session membership is required.");
  }
  if (!userResponse.ok || !sessionResponse.ok) {
    throw upstreamError("senti_unavailable", "Senti membership verification is unavailable.");
  }

  const userPayload = await boundedResponseJson(userResponse);
  const sessionPayload = await boundedResponseJson(sessionResponse);
  const user = asRecord(userPayload);
  const sessionRoot = asRecord(sessionPayload);
  const session = isRecord(sessionRoot.session) ? sessionRoot.session : sessionRoot;

  const humanId = nonemptyString(user.id, 200);
  if (!humanId) {
    throw upstreamError("invalid_senti_identity", "Senti returned an invalid identity.");
  }
  const membershipRole = readMembershipRole(session);
  if (!membershipRole) {
    throw new HttpError(403, "not_a_session_member", "Session membership is required.");
  }
  const tenantId = nonemptyOpaqueId(session.tenantId);
  if (!tenantId) {
    throw upstreamError(
      "senti_tenant_identity_unavailable",
      "Senti did not return the server-owned tenant identity required for voice isolation.",
    );
  }

  return {
    tenantId,
    humanId,
    displayName: safeDisplayName(user),
    membershipRole,
  };
}

function nonemptyOpaqueId(value: unknown): string | null {
  return typeof value === "string" &&
    value.length >= 1 &&
    value.length <= 160 &&
    /^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(value)
    ? value
    : null;
}

function bearerFrom(request: Request): string {
  const authorization = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9._~+/-]{16,8192})$/.exec(authorization);
  if (!match?.[1]) {
    throw new HttpError(401, "unauthorized", "A valid Senti bearer is required.");
  }
  return match[1];
}

function normalizedBaseUrl(value: string): string {
  try {
    const url = new URL(value);
    const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
    if (url.protocol !== "https:" && !(local && url.protocol === "http:")) throw new Error();
    url.pathname = "";
    url.search = "";
    url.hash = "";
    return url.toString().replace(/\/$/, "");
  } catch {
    throw upstreamError("invalid_senti_configuration", "Senti API configuration is invalid.");
  }
}

async function boundedResponseJson(response: Response): Promise<unknown> {
  const bytes = await response.arrayBuffer();
  if (bytes.byteLength > 64 * 1024) {
    throw upstreamError("invalid_senti_response", "Senti returned an invalid response.");
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw upstreamError("invalid_senti_response", "Senti returned an invalid response.");
  }
}

function readMembershipRole(session: Record<string, unknown>): SentiMembershipRole | null {
  const raw = session.membershipRole ?? session.membership_role;
  return typeof raw === "string" && MEMBERSHIP_ROLES.has(raw as SentiMembershipRole)
    ? (raw as SentiMembershipRole)
    : null;
}

function safeDisplayName(user: Record<string, unknown>): string {
  const github = nonemptyString(user.githubUsername ?? user.github_username, 80);
  return github ?? "Senti member";
}

function nonemptyString(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return normalized.length > 0 && normalized.length <= max ? normalized : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function asRecord(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) {
    throw upstreamError("invalid_senti_response", "Senti returned an invalid response.");
  }
  return value;
}

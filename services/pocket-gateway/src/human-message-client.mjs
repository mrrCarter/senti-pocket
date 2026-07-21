// human-message-client.mjs — the concrete gateway->api client for the HUMAN write door (executeAction humanMessage mode).
//
// Zero-dep + injected fetch: the deploy owns the HTTP transport; this module shapes the ONE request that authors a
// message AS the human (human-mrrcarter) under the USER's OWN bearer. No gateway/service credential is ever used here —
// confused-deputy-safe by construction: the caller's token is the sole authority in the path. The gateway's KMS
// receipt-signing key never touches this leg; it signs the ActionReceipt separately, server-side.
//
// Contract — must match api `src/routes/sessions.py` (router prefix "/sessions", mounted under "/api/v1" @ main.py:171):
//   POST /api/v1/sessions/{sessionId}/human-message
//   request : Authorization: Bearer <userToken>;  JSON { message, clientId }   (SessionHumanMessagePayload; both
//             `message`/`text` and `clientId`/`client_id` are accepted server-side via populate_by_name)
//   response: JSON { ok, message:{ id, cursor, senderId, ... }, event:{ sequenceId, agent:{ id }, ... } }
//
// The response body is returned RAW (text). actions.mjs `parseHumanMessageResult` validates it and returns null on any
// response missing `message.id` or `event.sequenceId` — so a 4xx/5xx/degraded/shape-drift response becomes a NON-landing
// (executeAction never finalizes `.posted`), fail-closed. That closes Atlas silent-false-fail #1 at the transport edge.

const DEFAULT_TIMEOUT_MS = 10_000;

/** Full api path for a human write. Kept greppable + pinned to the api route definition. */
function humanMessagePath(sessionId) {
  return `/api/v1/sessions/${encodeURIComponent(sessionId)}/human-message`;
}

/**
 * @param {object}   opts
 * @param {Function} opts.fetch       injected fetch (deploy-owned transport; e.g. global fetch or undici)
 * @param {string}   opts.apiBaseUrl  api ORIGIN (e.g. "https://api.sentinelayer.com"); the "/api/v1/sessions/..." path
 *                                    is appended. Trailing slashes are trimmed.
 * @param {number}   [opts.timeoutMs] bounded wait before abort (default 10s) — an execute must not hang on the api.
 * @returns {(sessionId: string, text: string, o?: { clientId?: string, token?: string }) => Promise<string>}
 *          postHumanMessage — resolves to the RAW response body text (for parseHumanMessageResult).
 */
export function createHumanMessageClient({ fetch, apiBaseUrl, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  if (typeof fetch !== 'function') throw new Error('createHumanMessageClient: fetch is required');
  const base = String(apiBaseUrl || '').replace(/\/+$/, '');
  if (!base) throw new Error('createHumanMessageClient: apiBaseUrl is required');

  return async function postHumanMessage(sessionId, text, o = {}) {
    const { clientId, token } = o;
    if (!sessionId || typeof sessionId !== 'string') throw new Error('postHumanMessage: sessionId required');
    if (typeof text !== 'string') throw new Error('postHumanMessage: text must be a string');
    // The user's own bearer is the ONLY authority for a human write. Refuse without it — never fall back to a gateway
    // credential (that would be the confused deputy). This throw carries NO token value.
    if (!token || typeof token !== 'string') throw new Error('postHumanMessage: user bearer token required');

    const url = base + humanMessagePath(sessionId);
    // Omit clientId when absent so the server derives its own idempotency key; when present (the deterministic proposal
    // hash) it doubles as the server-side idempotency token AND the read-back bind to THIS exact proposal.
    const body = JSON.stringify(clientId ? { message: text, clientId } : { message: text });

    // Normalize to a SINGLE Bearer: the caller may pass a raw credential or a full "Bearer <cred>" header (the /execute
    // handler currently threads the incoming Authorization header verbatim), and neither may double-wrap. NOTE: the token
    // PROVENANCE — that this is the USER's senti write credential, not the AIdenID gateway-auth/DPoP token — is an
    // upstream concern at the threading seam (tracked cross-lane); this client only guarantees a well-formed Bearer.
    const credential = token.replace(/^Bearer\s+/i, '');

    // Bounded wait: abort rather than hang the execute path. AbortSignal.timeout is Node 18.17+/20+ — guard for absence.
    const signal = (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function')
      ? AbortSignal.timeout(timeoutMs)
      : undefined;

    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        // The credential appears ONLY here, in the Authorization header. It is never logged, echoed into an error, or
        // written into a receipt/preview. This module performs no logging at all.
        authorization: `Bearer ${credential}`,
      },
      body,
      ...(signal ? { signal } : {}),
    });

    // Return the RAW body regardless of HTTP status. We deliberately do NOT throw on non-2xx: parseHumanMessageResult
    // null-safes any non-success shape into a NON-landing (fail-closed), whereas throwing here would surface a transport
    // error the execute path treats as offline->pending. Both are safe (never a false success); returning the body keeps
    // the success path a single JSON parse and lets the caller's read-back confirm the durable landing.
    return await res.text();
  };
}

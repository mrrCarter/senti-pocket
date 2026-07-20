// handlers.mjs — the deployed gateway API (Echo IMPLEMENTATION CLAIM HOLD: these endpoints did not exist).
// Framework-agnostic: createGateway(deps).handle({method,path,query,headers,body}) -> {status,headers,body,isBase64Encoded?}.
// Drop into Lambda/API Gateway or a local http server via a thin adapter. All I/O is injected (hermetic tests, no live calls).
//
// AUTH BOUNDARY (fail-closed): every non-health route REQUIRES a valid AIdenID-issued token. The human identity comes
// from the token (ConsumerAccount.id), NEVER from the request body. Authorization to write is server-derived
// (knownSessionIdsFor(humanId)) — a client can never name an arbitrary target session.
// Token model (per Echo's AIdenID research): atk_ = workload/project token; the phone uses a human-bound,
// audience/resource-scoped token minted via /v1/sessions/exchange (DPoP-bound). deps.verifyToken owns that check.
import { executeAction, findLandedByProposal } from './actions.mjs';
import { withLock } from './store.mjs';
import { extractCheckpoint } from './extract.mjs';
import { summarize } from './summarize.mjs';
import { buildSignedBundle } from './bundle.mjs';

const json = (status, body, headers = {}) => ({ status, headers: { 'content-type': 'application/json', ...headers }, body });

/**
 * Map an ActionReceipt to a response (warden contract ruling): a receipt whose confirmation binding was NEVER
 * established (status failed AND confirmedProposalHash == null) is NOT a valid frozen ActionReceipt — return a TYPED
 * ERROR ENVELOPE instead of a null-hash "receipt". A posted / pending / post-confirmation-failed receipt (which
 * carries the verified non-null hash) is returned as-is.
 */
const receiptResponse = (r) => (r && r.status === 'failed' && r.confirmedProposalHash == null)
  ? json(422, { error: 'proposal_rejected', reason: (r.failureReason || 'proposal could not be bound to a confirmation') })
  : json(200, r);
const readBody = (body) => {
  if (body == null) return {};
  if (typeof body === 'string') { try { return JSON.parse(body); } catch { return null; } }
  return body;
};
const hasScope = (ctx, scope) => Array.isArray(ctx.scopes) && ctx.scopes.includes(scope);

/**
 * Durable-state key namespaced by the authenticated human. A NUL separator is injection-safe: it cannot appear in a
 * humanId or a proposal.id, so ("a","bc") and ("ab","c") can never collide. Exported so callers/tests derive the
 * exact key rather than hardcoding the separator.
 */
export const storeKey = (humanId, id) => `${String(humanId).length}:${humanId}:${id}`;

/**
 * @param {{
 *   verifyToken: (headers:object)=>Promise<{humanId:string,scopes?:string[]}|null>,
 *   store: object,                       // async store (store.mjs)
 *   run: (args:string[])=>string,        // sl runner (actions execute + read-back)
 *   signingKey: any, signingKeyId: string,
 *   knownSessionIdsFor: (humanId:string)=>Promise<string[]>,
 *   bundleStore?: { listForHuman:(humanId:string,since:number)=>Promise<object[]> },
 *   ttsBackend?: (text:string,opts:object)=>Promise<{audio:Buffer,format:string}>,
 *   agent?: string, now?: ()=>string, freshnessSeconds?: number,
 * }} deps
 */
export function createGateway(deps) {
  // Route scope requirements, aligned to AIdenID's granted scopes. write => execute; read => sync. TTS requires a
  // DISTINCT least-privilege `pocket:voice` (Echo): it triggers third-party voice processing/egress, not a passive
  // read, so a read+write token must NOT authorize it. Override via deps.scopes if the contract changes.
  const SCOPES = { execute: 'sessions:write', sync: 'sessions:read', tts: 'pocket:voice', ...(deps.scopes || {}) };

  async function authenticate(req) {
    if (typeof deps.verifyToken !== 'function') return null; // no verifier wired => deny everything (fail-closed)
    try { return await deps.verifyToken(req.headers || {}); } catch { return null; }
  }

  async function handleSync(req, ctx) {
    if (!hasScope(ctx, SCOPES.sync)) return json(403, { error: 'missing scope ' + SCOPES.sync });
    if (!deps.bundleStore) return json(501, { error: 'sync backend not configured' });
    const since = Number((req.query && req.query.since) || 0);
    const sinceSeq = Number.isSafeInteger(since) && since > 0 ? since : 0;
    // scope bundles to the full principal (tenant isolation) — a site-A credential never lists site-B bundles.
    const bundles = await deps.bundleStore.listForHuman(ctx.principal || ctx.humanId, sinceSeq);
    return json(200, { bundles: Array.isArray(bundles) ? bundles : [] });
  }

  // GET /checkpoint?sessionId=...[&checkpointId=...] — "pull the exact checkpoint" (Carter).
  // Extracts a session's exact DURABLE checkpoint, summarizes, and returns it SIGNED so the phone verifies it offline.
  // Fail-closed throughout: membership-gated authz (a principal may pull ONLY sessions they belong to — no confused
  // deputy); extractCheckpoint throws (no synthesis) on a partial/missing range; buildBundle asserts semantics + re-applies
  // the egress scrub before signing, so a secret-bearing or malformed checkpoint can never be signed. Errors are honest +
  // retryable, never a fabricated bundle.
  async function handleCheckpoint(req, ctx) {
    if (!hasScope(ctx, SCOPES.sync)) return json(403, { error: 'missing scope ' + SCOPES.sync });
    const sessionId = req.query && req.query.sessionId;
    if (typeof sessionId !== 'string' || sessionId.length === 0) return json(400, { error: 'sessionId required' });
    if (!deps.signingKey) return json(501, { error: 'signing not configured' });
    // Server-derived membership authz (Echo cross-tenant): scope by the FULL principal, never the token's claim alone.
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.principal || ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
    if (!Array.isArray(known) || !known.includes(sessionId)) return json(403, { error: 'not a known session for this principal' });
    const now = () => (typeof deps.now === 'function' ? deps.now() : new Date().toISOString());
    let bundle;
    try {
      const checkpointId = (req.query && req.query.checkpointId) || undefined;
      const extracted = extractCheckpoint(sessionId, { run: deps.run, checkpointId });
      const summary = summarize(extracted.rawCheckpoint, extracted.checkpoint);
      bundle = buildSignedBundle(extracted.rawCheckpoint, summary, deps.signingKey, { signingKeyId: deps.signingKeyId, createdAt: now() });
    } catch (e) {
      // No durable checkpoint contained in the export window, empty export, etc. Honest + retryable — never a fake bundle.
      return json(503, { error: 'checkpoint not available', reason: String((e && e.message) || e), retryable: true });
    }
    return json(200, { bundle });
  }

  async function handleExecute(req, ctx) {
    if (!hasScope(ctx, SCOPES.execute)) return json(403, { error: 'missing scope ' + SCOPES.execute });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const { proposal, confirmation } = body;
    if (!proposal || typeof proposal.id !== 'string' || proposal.id.length === 0) return json(400, { error: 'proposal.id required' });

    // Authorization is server-derived: this human may only write to sessions they actually belong to.
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }

    const id = proposal.id;
    const now = () => (typeof deps.now === 'function' ? deps.now() : new Date().toISOString());
    // CROSS-TENANT ISOLATION (Echo): namespace ALL durable state + the lock by the FULL principal (issuer + aud/
    // resource + site + pairwise sub), not the sub alone — a credential for site A must never collide at site B.
    const key = storeKey(ctx.principal || ctx.humanId, id);

    const lockRes = await withLock(deps.store, key, async () => {
      const rec = await deps.store.get(key);
      if (rec && rec.status === 'posted') return json(200, rec); // idempotent replay of a terminal receipt
      const map = new Map();

      if (rec && rec.__emitted) {
        // A post already executed for this (principal,id) last time; executeAction re-verifies, never re-posts.
        map.set(id, rec);
      } else if (rec && rec.state === 'in-flight') {
        // AMBIGUOUS / crash recovery (Echo P0): a prior attempt reserved and MAY have committed remotely. Disambiguate
        // by content read-back BEFORE any re-post. If our post is in the room -> finalize it. If NOT found, we must NOT
        // convert an ambiguous outcome into a re-post from one bounded read miss — preserve the unknown state and
        // require reconciliation rather than risk a duplicate governed write.
        const landed = findLandedByProposal(proposal.targetSessionId, { proposal, run: deps.run, agent: deps.agent });
        if (landed) map.set(id, { status: 'failed', proposalId: id, __emitted: { parsed: landed, executedAt: rec.reservedAt || now() } });
        else return json(409, { error: 'prior send outcome unknown; not re-posting — reconciliation required', proposalId: id });
      } else {
        // First attempt: write a DURABLE in-flight reservation BEFORE the external post, so a crash/ambiguous-then-retry
        // takes the recovery branch above instead of blindly re-posting. (Prod store: conditional put-if-absent.)
        await deps.store.put(key, { state: 'in-flight', proposalId: id, reservedAt: now() });
      }

      const receipt = executeAction(proposal, confirmation, {
        store: map, run: deps.run, knownSessionIds: known,
        signingKey: deps.signingKey, signingKeyId: deps.signingKeyId,
        agent: deps.agent, now: now(), freshnessSeconds: deps.freshnessSeconds,
      });
      const persisted = map.get(id); // posted / emitted marker
      if (persisted) await deps.store.put(key, persisted);
      else if (receipt.ambiguous) { /* AMBIGUOUS send: PRESERVE the durable in-flight reservation (do NOT clear) so a
                                       retry reconciles via read-back instead of re-posting a possibly-committed write. */ }
      else if (receipt.status === 'failed') await deps.store.delete(key); // definitive pre-post failure -> clear reservation
      return receiptResponse(receipt); // null-hash (non-bindable) failures -> typed 422 error envelope, never a receipt
    });

    if (!lockRes.locked) {
      // Another instance holds the lock. Idempotent read if already terminal; else ask the caller to retry.
      const rec = await deps.store.get(key);
      if (rec && rec.status === 'posted') return json(200, rec);
      return json(409, { error: 'proposal execution in progress; retry' });
    }
    return lockRes.value; // fn already returned a json() descriptor
  }

  async function handleTts(req, ctx) {
    if (!hasScope(ctx, SCOPES.tts)) return json(403, { error: 'missing scope ' + SCOPES.tts });
    if (typeof deps.ttsBackend !== 'function') return json(501, { error: 'tts backend not configured' });
    const body = readBody(req.body);
    if (!body || typeof body.text !== 'string' || body.text.length === 0) return json(400, { error: 'text required' });
    if (Buffer.byteLength(body.text, 'utf8') > 8192) return json(413, { error: 'text exceeds 8192 bytes' });
    // The ElevenLabs key lives ONLY in deps.ttsBackend — it never reaches the phone. Echo owns the voice model.
    let out;
    try {
      out = await deps.ttsBackend(body.text, {
        voiceId: body.voiceId, modelId: body.modelId || 'eleven_flash_v2_5',
        outputFormat: body.outputFormat || 'pcm_24000', tone: body.tone,
      });
    } catch { return json(502, { error: 'tts backend error' }); }
    if (!out || !Buffer.isBuffer(out.audio)) return json(502, { error: 'tts backend returned no audio' });
    return {
      status: 200,
      headers: { 'content-type': 'application/octet-stream', 'x-senti-audio-format': out.format || 'pcm_s16le_24000' },
      body: out.audio,
      isBase64Encoded: true, // API Gateway binary contract; local adapter can ignore
    };
  }

  return {
    async handle(req) {
      const method = (req.method || 'GET').toUpperCase();
      const path = req.path || '/';
      if (method === 'GET' && path === '/health') return json(200, { ok: true });

      const ctx = await authenticate(req);
      if (!ctx || typeof ctx.humanId !== 'string' || !ctx.humanId) {
        return json(401, { error: 'authentication required' }, { 'www-authenticate': 'Bearer' });
      }
      if (method === 'GET' && path === '/sync') return handleSync(req, ctx);
      if (method === 'GET' && path === '/checkpoint') return handleCheckpoint(req, ctx);
      if (method === 'POST' && path === '/actions/execute') return handleExecute(req, ctx);
      if (method === 'POST' && path === '/tts') return handleTts(req, ctx);
      return json(404, { error: 'not found' });
    },
  };
}

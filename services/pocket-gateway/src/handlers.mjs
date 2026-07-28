// handlers.mjs — the deployed gateway API (Echo IMPLEMENTATION CLAIM HOLD: these endpoints did not exist).
// Framework-agnostic: createGateway(deps).handle({method,path,query,headers,body}) -> {status,headers,body,isBase64Encoded?}.
// Drop into Lambda/API Gateway or a local http server via a thin adapter. All I/O is injected (hermetic tests, no live calls).
//
// AUTH BOUNDARY (fail-closed): every non-health route REQUIRES a valid AIdenID-issued token. The human identity comes
// from the token (ConsumerAccount.id), NEVER from the request body. Authorization to write is server-derived
// (knownSessionIdsFor(humanId)) — a client can never name an arbitrary target session.
// Token model (per Echo's AIdenID research): atk_ = workload/project token; the phone uses a human-bound,
// audience/resource-scoped token minted via /v1/sessions/exchange (DPoP-bound). deps.verifyToken owns that check.
import { randomUUID, createHash } from 'node:crypto';
import { executeAction, findLandedByProposal } from './actions.mjs';
import { withLock } from './store.mjs';
import { extractCheckpoint } from './extract.mjs';
import { summarize } from './summarize.mjs';
import { buildSignedBundle } from './bundle.mjs';
import { routeAnswer } from './reasoning-router.mjs';
import { splitTagged } from './audio-tags.mjs';
import { scrubText } from './scrub.mjs';
import { renderDeck } from './deck/templates.mjs';
import { narrateDeck } from './deck/narration.mjs';
import { buildStoryboard, assembleDeckVideo } from './deck/video.mjs';
import { createDialRegistry } from './dial-registry.mjs';
import { mapSignalToPushInput } from './need-carter-dial.mjs';
import { groundingIdsFromBundle, keepGrounded, isGrounded } from './grounding-gate.mjs';

const json = (status, body, headers = {}) => ({ status, headers: { 'content-type': 'application/json', ...headers }, body });

/**
 * Map an ActionReceipt to a response (warden contract ruling): a receipt whose confirmation binding was NEVER
 * established (status failed AND confirmedProposalHash == null) is NOT a valid frozen ActionReceipt — return a TYPED
 * ERROR ENVELOPE instead of a null-hash "receipt". A posted / pending / post-confirmation-failed receipt (which
 * carries the verified non-null hash) is returned as-is.
 */
export const receiptResponse = (r) => {
  if (r && r.status === 'failed' && r.confirmedProposalHash == null) {
    return json(422, { error: 'proposal_rejected', reason: (r.failureReason || 'proposal could not be bound to a confirmation') });
  }
  // Strip the internal __emitted reconcile marker (the EMITTED-RETRY signal set in actions.mjs) — it must NEVER cross
  // into the response body (contract: the client gets a clean ActionReceipt, not gateway-internal reconcile state).
  if (r && typeof r === 'object' && '__emitted' in r) { const { __emitted, ...clean } = r; return json(200, clean); }
  return json(200, r);
};
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
 * Idempotency key for a ring-owner dispatch (PR-B4). An explicit caller `idempotencyKey` wins (bounded); otherwise a
 * content hash of the ring's INTENT (session + question + kind + options) so a naive network RETRY of the identical body
 * dedupes to the same dialId automatically. Distinct intentional rings (different content) or a re-ring after the TTL
 * window get a fresh dialId. Prefixed (k:/h:) so an explicit key can never collide with a content hash.
 */
export function ringIdempotencyKey(body = {}) {
  const explicit = typeof body.idempotencyKey === 'string' && body.idempotencyKey.trim() ? body.idempotencyKey.trim().slice(0, 200) : '';
  if (explicit) return 'k:' + explicit;
  const sessionId = body.context && typeof body.context.sessionId === 'string' ? body.context.sessionId : '';
  const q = typeof body.question === 'string' ? body.question.trim() : '';
  const kindStr = typeof body.kind === 'string' ? body.kind : 'info';
  const opts = Array.isArray(body.options) ? body.options.join('') : '';
  const h = createHash('sha256').update([sessionId, q, kindStr, opts].map((v) => { const t = String(v); return `${t.length}:${t}`; }).join(''), 'utf8').digest('base64url').slice(0, 32);
  return 'h:' + h;
}

/**
 * @param {{
 *   verifyToken: (headers:object)=>Promise<{humanId:string,scopes?:string[]}|null>,
 *   store: object,                       // async store (store.mjs)
 *   run: (args:string[])=>string,        // sl runner (actions execute + read-back)
 *   signingKey: any, signingKeyId: string,
 *   knownSessionIdsFor: (humanId:string)=>Promise<string[]>,
 *   bundleStore?: { listForHuman:(humanId:string,since:number)=>Promise<object[]> },
 *   dialSignalStore?: { get:(dialId:string)=>Promise<object|undefined> },  // GET /dial?id= LEAN-ring hydration (createDialSignalStore)
 *   ttsBackend?: (text:string,opts:object)=>Promise<{audio:Buffer,format:string}>,
 *   agent?: string, now?: ()=>string, freshnessSeconds?: number,
 * }} deps
 */
export function createGateway(deps) {
  // Route scope requirements, aligned to AIdenID's granted scopes. write => execute; read => sync. TTS requires a
  // DISTINCT least-privilege `pocket:voice` (Echo): it triggers third-party voice processing/egress, not a passive
  // read, so a read+write token must NOT authorize it. Override via deps.scopes if the contract changes.
  const SCOPES = { execute: 'sessions:write', sync: 'sessions:read', tts: 'pocket:voice', dial: 'pocket:dial', ...(deps.scopes || {}) };
  // /dial/register substrate: binds a device VoIP token to a session (deploy wires deps.deviceRegistry to Dynamo; the
  // registry defers a missing backend to a register-time 501, so constructing it unconditionally is safe). now defaults
  // to Date.now (ms) — the registeredAt stamp only.
  const dialReg = createDialRegistry({ deviceRegistry: deps.deviceRegistry });

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
    // Server-derived membership authz: knownSessionIdsFor is keyed by HUMANID (the contract + the write path
    // handleExecute), so scope by ctx.humanId — NOT the synthetic principal string (which never matches -> 403s a valid
    // member in prod). Durable state stays principal-namespaced (below); membership is humanId. The token's claim alone
    // still can never name an arbitrary target session.
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
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

  // POST /answer — the "reason / clarify, don't refuse" fix (Carter). Grounds a question in the
  // session's exact VERIFIED checkpoint and routes GROUNDING-FIRST (routeAnswer): a confident LLM
  // with no retrieval grounding is NEVER "answered" — it becomes clarify/unavailable, never a flat
  // refuse and never a hallucinated cite. Fail-closed like /checkpoint: membership-gated (no confused
  // deputy), reasons ONLY over a signature-verified bundle (never synthesizes), honest 503 when no
  // durable checkpoint exists. The LLM key lives ONLY in deps.reason — it never reaches the phone.
  async function handleAnswer(req, ctx) {
    if (!hasScope(ctx, SCOPES.sync)) return json(403, { error: 'missing scope ' + SCOPES.sync });
    if (typeof deps.reason !== 'function') return json(501, { error: 'reasoning backend not configured' });
    if (!deps.signingKey) return json(501, { error: 'signing not configured' });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const sessionId = body.sessionId;
    const question = typeof body.question === 'string' ? body.question.trim() : '';
    if (typeof sessionId !== 'string' || sessionId.length === 0) return json(400, { error: 'sessionId required' });
    if (!question) return json(400, { error: 'question required' });
    if (Buffer.byteLength(question, 'utf8') > 4096) return json(413, { error: 'question exceeds 4096 bytes' });
    // Server-derived membership authz: reason ONLY over a session this HUMAN belongs to (humanId-keyed, matching the write).
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
    if (!Array.isArray(known) || !known.includes(sessionId)) return json(403, { error: 'not a known session for this principal' });
    const now = () => (typeof deps.now === 'function' ? deps.now() : new Date().toISOString());
    // Fail-closed: reason ONLY over a signature-verified checkpoint bundle (never over an unverified/synthesized one).
    let bundle;
    try {
      const checkpointId = body.checkpointId || undefined;
      const extracted = extractCheckpoint(sessionId, { run: deps.run, checkpointId });
      const summary = summarize(extracted.rawCheckpoint, extracted.checkpoint);
      bundle = buildSignedBundle(extracted.rawCheckpoint, summary, deps.signingKey, { signingKeyId: deps.signingKeyId, createdAt: now() });
    } catch (e) {
      return json(503, { error: 'checkpoint not available', reason: String((e && e.message) || e), retryable: true });
    }
    // The GROUNDING = evidence ids in the verified bundle. routeAnswer intersects the LLM's claimed
    // cites with this set (dropping hallucinated ones), so a citation can only be real grounded evidence.
    const groundedEvidenceIds = groundingIdsFromBundle(bundle);
    let reasoned;
    try {
      reasoned = await deps.reason({ question, bundle, groundedEvidenceIds });
    } catch { return json(502, { error: 'reasoning backend error' }); }
    const r = reasoned && typeof reasoned === 'object' ? reasoned : {};
    const routed = routeAnswer(
      {
        groundedEvidenceIds,
        llmAnswer: { text: r.text, taggedText: r.taggedText, evidenceIds: r.evidenceIds, llmConfidence: r.llmConfidence },
        nearestTopics: r.nearestTopics,
      },
      { minConfidence: deps.minConfidence },
    );
    // Provenance: which verified checkpoint the answer was grounded in (auditable, phone-verifiable).
    return json(200, { ...routed, checkpointId: bundle.checkpointId, contractsVersion: bundle.contractsVersion });
  }

  // POST /brief — a REASONED, segmented briefing (fixes "too brief / no reasoning", Carter). Same
  // fail-closed wedge as /answer: membership-gated, reasons ONLY over the signature-verified checkpoint,
  // honest 503 when no durable checkpoint. GROUNDING-FIRST: each segment's cites are intersected with the
  // verified bundle's evidence (hallucinated cites dropped), and a segment with no grounded evidence is
  // dropped — the briefing is grounded ground-truth, never fabricated. Each surviving segment carries
  // BOTH taggedText (audio-tagged, for ElevenLabs) and plain text (for AVSpeech/OpenAI-TTS) via splitTagged.
  async function handleBrief(req, ctx) {
    if (!hasScope(ctx, SCOPES.sync)) return json(403, { error: 'missing scope ' + SCOPES.sync });
    if (typeof deps.brief !== 'function') return json(501, { error: 'briefing backend not configured' });
    if (!deps.signingKey) return json(501, { error: 'signing not configured' });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const sessionId = body.sessionId;
    if (typeof sessionId !== 'string' || sessionId.length === 0) return json(400, { error: 'sessionId required' });
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
    if (!Array.isArray(known) || !known.includes(sessionId)) return json(403, { error: 'not a known session for this principal' });
    const now = () => (typeof deps.now === 'function' ? deps.now() : new Date().toISOString());
    let bundle;
    try {
      const checkpointId = body.checkpointId || undefined;
      const extracted = extractCheckpoint(sessionId, { run: deps.run, checkpointId });
      const summary = summarize(extracted.rawCheckpoint, extracted.checkpoint);
      bundle = buildSignedBundle(extracted.rawCheckpoint, summary, deps.signingKey, { signingKeyId: deps.signingKeyId, createdAt: now() });
    } catch (e) {
      return json(503, { error: 'checkpoint not available', reason: String((e && e.message) || e), retryable: true });
    }
    const groundedEvidenceIds = groundingIdsFromBundle(bundle);
    let briefed;
    try {
      briefed = await deps.brief({ bundle, groundedEvidenceIds });
    } catch { return json(502, { error: 'briefing backend error' }); }
    const rawSegments = briefed && Array.isArray(briefed.segments) ? briefed.segments : [];
    const segments = rawSegments
      .map((seg) => {
        const s = seg && typeof seg === 'object' ? seg : {};
        const evidenceIds = keepGrounded(s.evidenceIds, groundedEvidenceIds); // drop hallucinated cites (shared honesty gate)
        const source = typeof s.taggedText === 'string' ? s.taggedText : (typeof s.text === 'string' ? s.text : '');
        const { tagged, plain } = splitTagged(source); // audio-tagged (ElevenLabs) + plain (AVSpeech/OpenAI-TTS)
        return { text: plain, taggedText: tagged, evidenceIds };
      })
      .filter(isGrounded); // grounding-first (shared gate): visible text (trim) + >=1 grounded cite — was seg.text-truthy, which kept whitespace-only segments (parity with gemma-backend/brief-pipeline #69/#70)
    // `grounded:false` (no segment survived) is an HONEST "no reasoned briefing grounded in this checkpoint"
    // signal — the caller labels it (never a fabricated brief), same discipline as /answer's unavailable.
    return json(200, { segments, grounded: segments.length > 0, checkpointId: bundle.checkpointId, contractsVersion: bundle.contractsVersion });
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

    // MEMBERSHIP PRECHECK (Forge nit / Warden hardening): reject a non-member BEFORE the durable in-flight reservation
    // below, so an authenticated `sessions:write` principal can't amplify self-namespace storage by spamming /execute for
    // sessions they don't belong to. executeAction re-checks membership authoritatively (validateProposal, fail-closed on
    // empty `known`); this is the earlier, cheaper gate with the SAME notion of membership — no store touch on refuse.
    if (!known.includes(proposal.targetSessionId)) {
      return json(403, { error: 'not a member of the target session', proposalId: proposal.id });
    }

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

      const receipt = await executeAction(proposal, confirmation, {
        store: map, run: deps.run, knownSessionIds: known,
        signingKey: deps.signingKey, signingKeyId: deps.signingKeyId,
        agent: deps.agent, now: now(), freshnessSeconds: deps.freshnessSeconds,
        // humanMessage (native Pocket write) authoring: the async /human-message poster + the CALLER's bearer token so
        // the write authors as human-mrrcarter under the user's own identity. Unused for agent-kind proposals.
        postHumanMessage: deps.postHumanMessage,
        userToken: (req.headers && (req.headers.authorization || req.headers.Authorization)) || undefined,
        // NOTE: the humanMessage read-back identity is derived INSIDE verifyHumanMessageLanded from the POST response's
        // authored sender (parsed.senderId = the api's own event.agent.id) — the api's truth, not a predicted identity.
        // This `humanId` opt is retained for the agent read-back dispatch; it is not the human read-back's source.
        humanId: ctx.humanId ? `human-${ctx.humanId}` : undefined,
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
    // PUBLIC demo capability: reserve call+bytes against the persistent lifetime budget + per-min rate AFTER all
    // local validation and IMMEDIATELY before the provider. Reserve-before-provider; never refunded (provider spend
    // ambiguous). A demo ctx with no reserve fn is fail-closed (503) — never an unbounded synthesis.
    const isDemo = ctx && ctx.principal === 'pocket.demo';
    if (isDemo) {
      if (typeof deps.demoReserve !== 'function') return json(503, { error: 'demo_budget_unconfigured' });
      const demoRes = deps.demoReserve(ctx, Buffer.byteLength(body.text, 'utf8'));
      if (!demoRes || !demoRes.ok) return json((demoRes && demoRes.status) || 429, { error: (demoRes && demoRes.error) || 'demo_usage_exhausted' });
    }
    // The ElevenLabs key lives ONLY in deps.ttsBackend — it never reaches the phone. Echo owns the voice model.
    // Demo ctx: PIN every cost-affecting provider option (ignore client voice/model/output/tone) so an extracted
    // bearer cannot escalate provider cost; a real session keeps its overrides. Response bytes are capped too.
    let out;
    try {
      out = await deps.ttsBackend(body.text, isDemo ? {} : {
        voiceId: body.voiceId, modelId: body.modelId || 'eleven_flash_v2_5',
        outputFormat: body.outputFormat || 'pcm_24000', tone: body.tone,
      });
    } catch { return json(502, { error: 'tts backend error' }); }
    if (!out || !Buffer.isBuffer(out.audio)) return json(502, { error: 'tts backend returned no audio' });
    if (isDemo && out.audio.length > 4 * 1024 * 1024) return json(502, { error: 'tts response exceeds demo cap' });
    return {
      status: 200,
      headers: { 'content-type': 'application/octet-stream', 'x-senti-audio-format': out.format || 'pcm_s16le_24000' },
      body: out.audio,
      isBase64Encoded: true, // API Gateway binary contract; local adapter can ignore
    };
  }

  // POST /deck — render a presentation deck (deterministic SVG slides) + optional per-slide narration. The deck spec is
  // caller-authored (a valid session), so the base op is a read-scope content render; synthesizing audio is voice egress
  // and requires the DISTINCT pocket:voice scope (same boundary as /tts). Audio is opt-in (narrate:true) and honest: if
  // requested without a backend, segments carry audioSkipped='no-backend' rather than fabricating silence.
  async function handleDeck(req, ctx) {
    if (!hasScope(ctx, SCOPES.sync)) return json(403, { error: 'missing scope ' + SCOPES.sync });
    const body = readBody(req.body);
    if (body === null) return json(400, { error: 'invalid JSON body' });
    const spec = body && body.deck && typeof body.deck === 'object' ? body.deck : body;
    if (!spec || !Array.isArray(spec.slides) || spec.slides.length === 0) return json(400, { error: 'deck.slides required (non-empty array)' });
    if (spec.slides.length > 60) return json(413, { error: 'deck exceeds 60 slides' });
    const narrate = body.narrate === true || body.audio === true;
    if (narrate) {
      if (!hasScope(ctx, SCOPES.tts)) return json(403, { error: 'missing scope ' + SCOPES.tts + ' (required to synthesize narration audio)' });
      for (const s of spec.slides) {
        const script = (s && (s.script ?? (s.content && s.content.script))) || '';
        if (typeof script === 'string' && Buffer.byteLength(script, 'utf8') > 8192) return json(413, { error: 'a slide script exceeds 8192 bytes' });
      }
    }
    // format:'video' -> assemble an mp4. Fail FAST (before the expensive render+TTS) if the deploy hasn't injected the
    // raster + encoder tools.
    const wantVideo = body.format === 'video';
    if (wantVideo && (typeof deps.rasterize !== 'function' || typeof deps.encodeVideo !== 'function')) {
      return json(501, { error: 'video backend not configured', reason: 'no-video-capability' });
    }
    let rendered;
    try { rendered = renderDeck(spec); }
    catch (e) { return json(400, { error: 'render failed: ' + (e && e.message ? String(e.message).slice(0, 160) : 'invalid slide') }); }
    const narration = await narrateDeck(spec, {
      ttsBackend: narrate ? deps.ttsBackend : null,
      voiceId: body.voiceId, tone: body.tone, synthesize: narrate,
      modelId: body.modelId || 'eleven_flash_v2_5',
      // Compressed default (mp3 ~2 KB/s vs raw pcm ~48 KB/s) keeps a narrated deck's base64 well under the 6 MB response
      // limit; the aggregate cap is the hard safety net so a pcm override / huge deck degrades honestly, never 500s.
      outputFormat: body.outputFormat || 'mp3_44100_128',
      maxTotalAudioBytes: 5 * 1024 * 1024,
      maxSlideAudioBytes: 4 * 1024 * 1024, // per-slide bound (< aggregate) so ONE near-max/pcm slide can't alone blow the limit
      // Bound serial TTS round-trips (each ~1-3s) so a many-slide narrated deck can't exceed the request timeout. This
      // is a SAFETY bound; genuinely large decks should narrate via an async job, not one sync request.
      maxNarratedSlides: 30,
    });
    const slides = rendered.slides.map((s, i) => {
      const n = narration.segments[i];
      return {
        template: s.template, style: s.style, width: s.width, height: s.height, svg: s.svg,
        narration: n ? {
          transcript: n.transcript, tagged: n.tagged, hasAudioTags: n.hasAudioTags, tone: n.tone,
          audio: n.audio || null, format: n.format || null, audioSkipped: n.audioSkipped || null,
        } : null,
      };
    });
    if (wantVideo) {
      const storyboard = buildStoryboard(slides, { defaultSlideMs: body.slideMs, padMs: body.padMs });
      const MAX_VIDEO_MS = 10 * 60 * 1000; // 10 min — beyond this ffmpeg would blow Lambda's 15-min / API-GW 29s bounds
      if (storyboard.totalMs > MAX_VIDEO_MS) {
        return json(413, { error: 'video too long', reason: 'video-too-long', totalMs: storyboard.totalMs, maxMs: MAX_VIDEO_MS });
      }
      // deps.rasterize fetches <image href> during SVG->PNG. safeImageHref already limits hrefs to https/data:image, but
      // the injected rasterizer MUST run network-egress-disabled / sandboxed (deploy contract) as the hard SSRF backstop.
      const v = await assembleDeckVideo(storyboard, { rasterize: deps.rasterize, encodeVideo: deps.encodeVideo }, { fps: body.fps });
      if (!v.video) {
        return json(v.reason === 'no-video-capability' ? 501 : 502, { error: 'video assembly failed', reason: v.reason, failedIndex: v.failedIndex });
      }
      return {
        status: 200,
        headers: { 'content-type': 'video/mp4', 'x-senti-video-duration-ms': String(v.durationMs), 'x-senti-video-frames': String(v.frames) },
        body: v.video,           // raw mp4 Buffer, streamed as binary (no base64-in-JSON)
        isBase64Encoded: true,   // API Gateway binary contract; the local adapter ignores it
      };
    }
    return json(200, {
      style: rendered.style, count: rendered.count,
      audioEnabled: narration.audioEnabled, narratedCount: narration.narratedCount,
      audioBytes: narration.audioBytes, audioCapReached: narration.capReached,
      slides,
    });
  }

  // POST /dial — place a "ring Carter" push about a session decision (the DIAL-ME flow). It DISPATCHES a ring via the
  // injected deps.pushBackend and AUTHORS NOTHING (low-risk: it never posts as anyone). The grounded Q&A on the call
  // reuses /answer + /brief; the spoken VOICE-GO -> post reuses the governed /actions/execute humanMessage write (which
  // keeps its own bearer + confirm + hash gates — dialing does NOT relax the write's Carter-consent bar).
  // Least-privilege: a DISTINCT pocket:dial scope (placing a call is its own capability, not sessions:write).
  async function handleDial(req, ctx) {
    if (!hasScope(ctx, SCOPES.dial)) return json(403, { error: 'missing scope ' + SCOPES.dial });
    if (typeof deps.pushBackend !== 'function') return json(501, { error: 'dial backend not configured', reason: 'dial-not-configured' });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const message = typeof body.message === 'string' ? body.message : '';
    if (!message.trim()) return json(400, { error: 'message required' });
    if (Buffer.byteLength(message, 'utf8') > 4096) return json(413, { error: 'message exceeds 4096 bytes' });
    const sessionId = body.sessionId;
    if (typeof sessionId !== 'string' || !sessionId) return json(400, { error: 'sessionId required' });
    const priority = ['low', 'medium', 'high', 'urgent'].includes(body.priority) ? body.priority : 'medium';
    // Membership: only ring about a session this human belongs to (humanId-keyed, same as the read endpoints).
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
    if (!Array.isArray(known) || !known.includes(sessionId)) return json(403, { error: 'not a known session for this user' });
    // context may echo session text -> best-effort scrub + bound before it leaves via the push payload.
    const context = typeof body.context === 'string' ? scrubText(body.context).text.slice(0, 2048) : undefined;
    let out;
    try { out = await deps.pushBackend({ message, context, priority, sessionId, humanId: ctx.humanId }); }
    catch { return json(502, { error: 'dial backend error', reason: 'dispatch-failed' }); }
    const dispatched = !!(out && out.dispatched);
    const dialId = out && typeof out.dialId === 'string' ? out.dialId : null;
    return json(dispatched ? 200 : 502, dispatched ? { dialId, dispatched: true } : { dialId, dispatched: false, reason: (out && out.reason) || 'not-dispatched' });
  }

  // POST /dial/ring-owner — the EXPLICIT ring path (sl ring-owner / an agent's MCP tool). The caller DESCRIBES a need
  // (question + kind + session context); RELAY builds the canonical NeedCarterSignal server-side (opaque GATEWAY-generated
  // id, so a caller cannot choose the store key), maps it to the RICH dial input + the storedSignal (PR-B2), and dispatches
  // via the SAME pushBackend as /dial — so a LEAN ring hydrates via GET /dial?id=. SECURITY: the ring TARGET humanId is
  // ctx.humanId (verified auth), NEVER the body (confused-deputy); requestedBy is DISPLAY only. AUTHORS NOTHING (it rings;
  // the answered-call write keeps its own governed confirm). Fail-closed: no backend -> 501, non-member -> 403, malformed
  // pickOption -> 400, invalid/below-floor signal -> 422. This is the PRODUCER that feeds PR-B2's storedSignal store-write.
  async function handleRingOwner(req, ctx) {
    if (!hasScope(ctx, SCOPES.dial)) return json(403, { error: 'missing scope ' + SCOPES.dial });
    if (typeof deps.pushBackend !== 'function') return json(501, { error: 'dial backend not configured', reason: 'dial-not-configured' });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const question = typeof body.question === 'string' ? body.question.trim() : '';
    if (!question) return json(400, { error: 'question required' });
    if (Buffer.byteLength(question, 'utf8') > 4096) return json(413, { error: 'question exceeds 4096 bytes' });
    const ctxIn = body.context && typeof body.context === 'object' ? body.context : {};
    const sessionId = typeof ctxIn.sessionId === 'string' ? ctxIn.sessionId : '';
    if (!sessionId) return json(400, { error: 'context.sessionId required' });
    // pickOption is atomic with its options — reject an empty/absent set up front as a client error (else it fails closed
    // downstream in buildDialPayload as a 502, the wrong status for a caller mistake).
    if (body.kind === 'pickOption' && (!Array.isArray(body.options) || body.options.length === 0)) {
      return json(400, { error: 'pickOption requires at least one option' });
    }
    // Membership: only ring about a session this human belongs to (humanId-keyed, same gate as /dial + the read endpoints).
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
    if (!Array.isArray(known) || !known.includes(sessionId)) return json(403, { error: 'not a known session for this user' });
    // Build the canonical NeedCarterSignal server-side. id = GATEWAY-generated opaque (caller must NOT choose the store
    // key). confidence defaults to 1.0 (an explicit ask clears the ring floor). createdAt = Unix-epoch SECONDS (seam (c)
    // contract: atlas's NeedCarterSignal custom-decodes Unix-seconds-or-absent -> Date). question + whatWeNeed are
    // best-effort scrubbed before they leave via the push (normalizeSignal re-bounds them to DIAL_LIMITS downstream).
    const kind = body.kind === 'pickOption'
      ? { kind: 'pickOption', options: body.options }
      : (typeof body.kind === 'string' ? body.kind : 'info');
    const nowMs = (() => { const iso = typeof deps.now === 'function' ? deps.now() : new Date().toISOString(); const ms = Date.parse(iso); return Number.isFinite(ms) ? ms : Date.now(); })();
    const signal = {
      id: 'need_' + randomUUID(),
      kind,
      question: scrubText(question).text.slice(0, 4096),
      context: {
        sessionId,
        ...(typeof ctxIn.checkpointId === 'string' && ctxIn.checkpointId ? { checkpointId: ctxIn.checkpointId } : {}),
        whatWeNeed: typeof ctxIn.whatWeNeed === 'string' ? scrubText(ctxIn.whatWeNeed).text.slice(0, 2048) : '',
      },
      confidence: typeof body.confidence === 'number' && Number.isFinite(body.confidence) ? body.confidence : 1.0,
      ...(Array.isArray(body.evidenceSeqs) ? { evidenceSeqs: body.evidenceSeqs } : {}),
      requestedBy: typeof body.requestedBy === 'string' && body.requestedBy ? body.requestedBy.slice(0, 128) : (deps.agent || 'an agent'),
      createdAt: Math.floor(nowMs / 1000), // Unix-epoch SECONDS (seam (c) contract)
    };
    // The ring dispatch (shared): map -> pushBackend -> {status, body}. mapSignalToPushInput enforces the confused-deputy
    // guard (target humanId from ctx, never the signal) + the ring floor.
    const doDispatch = async () => {
      const mapped = mapSignalToPushInput(signal, { humanId: ctx.humanId });
      if (!mapped.ring) return { status: 422, body: { error: 'signal not rung', reason: mapped.reason, ...(mapped.error ? { detail: mapped.error } : {}) } };
      let out;
      try { out = await deps.pushBackend({ ...mapped.input, storedSignal: mapped.storedSignal }); }
      catch { return { status: 502, body: { error: 'dial backend error', reason: 'dispatch-failed' } }; }
      const dispatched = !!(out && out.dispatched);
      const dialId = (out && typeof out.dialId === 'string' ? out.dialId : null) || mapped.input.id;
      return { status: dispatched ? 200 : 502, body: dispatched ? { dialId, dispatched: true, kind: mapped.kind.slug } : { dialId, dispatched: false, reason: (out && out.reason) || 'not-dispatched' } };
    };

    // ROBUSTNESS (Warden #86 follow-up): idempotency + a soft per-human ring rate-limit, BEST-EFFORT over deps.store.
    // FAIL-OPEN: a store that is absent or erroring NEVER drops a genuine ring — the guard only DEDUPES a retry / limits a
    // storm on the happy path; the ring itself always proceeds when the store can't help. (This rings Carter's phone — a
    // missed ring is worse than a rare duplicate, so an infra problem must never suppress a real ring.)
    const store = deps.store;
    if (!store || typeof store.get !== 'function' || typeof store.put !== 'function' || typeof store.acquireLock !== 'function') {
      const r = await doDispatch();
      return json(r.status, r.body);
    }
    const rateMax = Number.isInteger(deps.ringRateMax) && deps.ringRateMax > 0 ? deps.ringRateMax : 20;             // rings per window per human
    const rateWindowSec = Number.isInteger(deps.ringRateWindowSec) && deps.ringRateWindowSec > 0 ? deps.ringRateWindowSec : 60;
    const idemTtlSec = Number.isInteger(deps.ringIdemTtlSec) && deps.ringIdemTtlSec > 0 ? deps.ringIdemTtlSec : 120; // dedupe window for an identical/keyed retry
    const nowSec = Math.floor(nowMs / 1000);
    const idemStoreKey = storeKey(ctx.principal || ctx.humanId, 'ring:' + ringIdempotencyKey(body));
    // The guarded ring: idempotent-replay check -> soft rate-limit -> dispatch -> record. Runs UNDER the per-idemKey lock.
    const runGuarded = async () => {
      // 1. Idempotent replay: an identical/keyed ring within the window returns the SAME dialId — never a 2nd ring.
      let prior;
      try { prior = await store.get(idemStoreKey); } catch { prior = undefined; } // read error -> fail-open (proceed to ring)
      if (prior && typeof prior.dialId === 'string' && Number.isFinite(prior.expiresAtSec) && nowSec < prior.expiresAtSec) {
        return { status: 200, body: { dialId: prior.dialId, dispatched: true, idempotent: true } };
      }
      // 2. Soft per-human ring rate-limit (fixed window; get->check->put, fail-open on store error). Only a genuine
      //    (non-replay) ring consumes a token — a deduped retry above never counts against the limit.
      const bucket = Math.floor(nowSec / rateWindowSec);
      const rateKey = storeKey(ctx.principal || ctx.humanId, 'ringrate:' + bucket);
      let cnt = 0;
      try { const rr = await store.get(rateKey); cnt = rr && Number.isFinite(rr.count) ? rr.count : 0; } catch { cnt = 0; }
      if (cnt >= rateMax) return { status: 429, body: { error: 'ring rate limit exceeded', reason: 'rate-limited', retryAfterSec: (bucket + 1) * rateWindowSec - nowSec } };
      try { await store.put(rateKey, { count: cnt + 1 }, { ttlEpochSec: (bucket + 2) * rateWindowSec }); } catch { /* best-effort */ }
      // 3. Dispatch the ring, then 4. record the idempotency result ONLY on a successful dispatch (a failed ring is
      //    immediately retryable — we never cache a failure).
      const r = await doDispatch();
      if (r.status === 200 && r.body && typeof r.body.dialId === 'string') {
        try { await store.put(idemStoreKey, { dialId: r.body.dialId, expiresAtSec: nowSec + idemTtlSec }, { ttlEpochSec: nowSec + idemTtlSec }); } catch { /* best-effort: a write miss just means a later retry may re-ring */ }
      }
      return r;
    };
    // SERIALIZE per idemKey so two concurrent identical retries can't both ring — acquired INLINE (not via withLock) so we
    // FAIL OPEN on an acquisition ERROR (Atlas/Warden #90 gap: withLock throws if store.acquireLock throws -> the ring would
    // DROP, violating never-drop-a-genuine-ring). Three cases: acquire THROWS -> infra error BEFORE any dispatch -> ring
    // anyway (same as absent-store); acquire -> null -> lock HELD (concurrent identical ring) -> 409 (don't double-ring);
    // acquire -> token -> run the guard, release BEST-EFFORT in finally (a release throw is swallowed so it can NEVER
    // re-dispatch -> no double-ring; the lock self-heals via its TTL).
    let token;
    try {
      token = await store.acquireLock(idemStoreKey);
    } catch {
      const r = await doDispatch(); // acquisition infra error, nothing dispatched yet -> fail-open, never drop the ring
      return json(r.status, r.body);
    }
    if (!token) return json(409, { error: 'a concurrent ring for this idempotency key is in flight', reason: 'ring-in-flight' });
    let guarded;
    try { guarded = await runGuarded(); }
    finally { try { await store.releaseLock(idemStoreKey, token); } catch { /* best-effort: the lock self-heals via TTL */ } }
    return json(guarded.status, guarded.body);
  }

  // POST /dial/register — bind THIS device's VoIP token to a session the human belongs to (the onVoipToken(hex) seam,
  // forge PR #40). The registry is dispatch-substrate for /dial: it AUTHORS NOTHING and holds no key. humanId comes from
  // the VERIFIED token (ctx.humanId), NEVER the body — a caller can only register a device under their OWN identity,
  // which is what makes /dial's ctx.humanId dispatch secure (register + dial + pushBackend lookup share the one key).
  // Same least-privilege pocket:dial scope. Fail-closed: no registry -> 501, bad token -> 400/413, non-member -> 403.
  async function handleDialRegister(req, ctx) {
    if (!hasScope(ctx, SCOPES.dial)) return json(403, { error: 'missing scope ' + SCOPES.dial });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const r = await dialReg.register({
      humanId: ctx.humanId,
      body,
      isMember: async (sid) => { const known = await deps.knownSessionIdsFor(ctx.humanId); return Array.isArray(known) && known.includes(sid); },
    });
    return json(r.status, r.body);
  }

  // GET /dial?id=<dialId> — hydrate a LEAN ring (dialPayloadV1 fetch=true shed ALL governed content). Returns the FULL
  // NeedCarterSignal that /dial dispatch stored keyed by the ring's dialId (== signal.id) — the exact object the app
  // decodes on pickup. AUTHZ: pocket:dial scope + the caller must be a MEMBER of the signal's session (the same
  // humanId-keyed gate as /dial + the read endpoints); the ring TARGET isn't stored, so session membership IS the
  // authorization boundary. OPAQUE-ID: the caller supplies a high-entropy dialId, NOT a session they named — so we must
  // never leak whether an id is valid to someone who can't access it. Absent, expired, AND non-member therefore collapse
  // to ONE 410 (gone): there is honestly no signal available to this caller, and it closes the existence oracle (distinct
  // from /checkpoint, where the client names the session so a 403 reveals nothing). No store wired -> 501; bad id -> 400.
  async function handleDialFetch(req, ctx) {
    if (!hasScope(ctx, SCOPES.dial)) return json(403, { error: 'missing scope ' + SCOPES.dial });
    if (!deps.dialSignalStore || typeof deps.dialSignalStore.get !== 'function') {
      return json(501, { error: 'dial hydration not configured', reason: 'dial-signal-store-not-configured' });
    }
    const id = req.query && typeof req.query.id === 'string' ? req.query.id : '';
    if (id.trim().length === 0) return json(400, { error: 'id required' });
    if (Buffer.byteLength(id, 'utf8') > 256) return json(400, { error: 'id too long' }); // bound before a store round-trip
    let signal;
    try { signal = await deps.dialSignalStore.get(id); }
    catch { return json(503, { error: 'dial hydration lookup failed', retryable: true }); }
    // Resolve membership from the STORED signal's session (only when a signal exists). Absent signal -> skip the lookup
    // (no session to check) -> the uniform 410 below; this also avoids a knownSessionIdsFor call per bogus-id probe.
    let member = false;
    const sessionId = signal && signal.context && typeof signal.context.sessionId === 'string' ? signal.context.sessionId : null;
    if (sessionId) {
      let known = [];
      try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }
      member = Array.isArray(known) && known.includes(sessionId);
    }
    if (!signal || !member) return json(410, { error: 'dial signal unavailable', reason: 'gone' }); // absent | expired | non-member -> uniform gone
    return json(200, signal);
  }

  return {
    async handle(req) {
      // handle() is the gateway's contract boundary — it must NEVER throw to an adapter (a throw becomes a runtime crash
      // / adapter-specific 5xx that can leak a stack). Any unexpected error from a handler collapses to a clean 500 here.
      try {
        const method = (req.method || 'GET').toUpperCase();
        const path = req.path || '/';
        if (method === 'GET' && path === '/health') return json(200, { ok: true });

        const ctx = await authenticate(req);
        if (!ctx || typeof ctx.humanId !== 'string' || !ctx.humanId) {
          return json(401, { error: 'authentication required' }, { 'www-authenticate': 'Bearer' });
        }
        // `return await` (not bare `return`): the handlers are async, so awaiting HERE keeps a rejection inside this
        // try/catch — a bare `return handleX()` would settle in the caller's await, escaping the boundary.
        if (method === 'GET' && path === '/sync') return await handleSync(req, ctx);
        if (method === 'GET' && path === '/checkpoint') return await handleCheckpoint(req, ctx);
        if (method === 'POST' && path === '/answer') return await handleAnswer(req, ctx);
        if (method === 'POST' && path === '/brief') return await handleBrief(req, ctx);
        if (method === 'POST' && path === '/actions/execute') return await handleExecute(req, ctx);
        if (method === 'POST' && path === '/tts') return await handleTts(req, ctx);
        if (method === 'POST' && path === '/deck') return await handleDeck(req, ctx);
        if (method === 'POST' && path === '/dial') return await handleDial(req, ctx);
        if (method === 'POST' && path === '/dial/ring-owner') return await handleRingOwner(req, ctx);
        if (method === 'GET' && path === '/dial') return await handleDialFetch(req, ctx);
        if (method === 'POST' && path === '/dial/register') return await handleDialRegister(req, ctx);
        return json(404, { error: 'not found' });
      } catch {
        return json(500, { error: 'internal error' }); // no stack/detail leaked to the client
      }
    },
  };
}

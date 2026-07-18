// handlers.mjs — the deployed gateway API (Echo IMPLEMENTATION CLAIM HOLD: these endpoints did not exist).
// Framework-agnostic: createGateway(deps).handle({method,path,query,headers,body}) -> {status,headers,body,isBase64Encoded?}.
// Drop into Lambda/API Gateway or a local http server via a thin adapter. All I/O is injected (hermetic tests, no live calls).
//
// AUTH BOUNDARY (fail-closed): every non-health route REQUIRES a valid AIdenID-issued token. The human identity comes
// from the token (ConsumerAccount.id), NEVER from the request body. Authorization to write is server-derived
// (knownSessionIdsFor(humanId)) — a client can never name an arbitrary target session.
// Token model (per Echo's AIdenID research): atk_ = workload/project token; the phone uses a human-bound,
// audience/resource-scoped token minted via /v1/sessions/exchange (DPoP-bound). deps.verifyToken owns that check.
import { executeAction } from './actions.mjs';
import { withLock } from './store.mjs';

const json = (status, body, headers = {}) => ({ status, headers: { 'content-type': 'application/json', ...headers }, body });
const readBody = (body) => {
  if (body == null) return {};
  if (typeof body === 'string') { try { return JSON.parse(body); } catch { return null; } }
  return body;
};
const hasScope = (ctx, scope) => Array.isArray(ctx.scopes) && ctx.scopes.includes(scope);

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
  async function authenticate(req) {
    if (typeof deps.verifyToken !== 'function') return null; // no verifier wired => deny everything (fail-closed)
    try { return await deps.verifyToken(req.headers || {}); } catch { return null; }
  }

  async function handleSync(req, ctx) {
    if (!hasScope(ctx, 'bundles:read')) return json(403, { error: 'missing scope bundles:read' });
    if (!deps.bundleStore) return json(501, { error: 'sync backend not configured' });
    const since = Number((req.query && req.query.since) || 0);
    const sinceSeq = Number.isSafeInteger(since) && since > 0 ? since : 0;
    const bundles = await deps.bundleStore.listForHuman(ctx.humanId, sinceSeq);
    return json(200, { bundles: Array.isArray(bundles) ? bundles : [] });
  }

  async function handleExecute(req, ctx) {
    if (!hasScope(ctx, 'actions:execute')) return json(403, { error: 'missing scope actions:execute' });
    const body = readBody(req.body);
    if (!body) return json(400, { error: 'invalid JSON body' });
    const { proposal, confirmation } = body;
    if (!proposal || typeof proposal.id !== 'string' || proposal.id.length === 0) return json(400, { error: 'proposal.id required' });

    // Authorization is server-derived: this human may only write to sessions they actually belong to.
    let known = [];
    try { known = await deps.knownSessionIdsFor(ctx.humanId); } catch { return json(500, { error: 'authorization lookup failed' }); }

    const id = proposal.id;
    const lockRes = await withLock(deps.store, id, async () => {
      const prior = await deps.store.get(id);
      const map = new Map();
      if (prior) map.set(id, prior); // seed executeAction so a prior emitted-marker re-verifies (never re-posts)
      const receipt = executeAction(proposal, confirmation, {
        store: map,
        run: deps.run,
        knownSessionIds: known,
        signingKey: deps.signingKey,
        signingKeyId: deps.signingKeyId,
        agent: deps.agent,
        now: typeof deps.now === 'function' ? deps.now() : undefined,
        freshnessSeconds: deps.freshnessSeconds,
      });
      const persisted = map.get(id); // only posted/pending/emitted are stored by executeAction; validation-fails aren't
      if (persisted) await deps.store.put(id, persisted);
      return receipt;
    });

    if (!lockRes.locked) {
      // A concurrent request on another instance holds the lock. Idempotent read if already terminal; else retry.
      const prior = await deps.store.get(id);
      if (prior && prior.status === 'posted') return json(200, prior);
      return json(409, { error: 'proposal execution in progress; retry' });
    }
    return json(200, lockRes.value);
  }

  async function handleTts(req, ctx) {
    if (!hasScope(ctx, 'tts')) return json(403, { error: 'missing scope tts' });
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
      if (method === 'POST' && path === '/actions/execute') return handleExecute(req, ctx);
      if (method === 'POST' && path === '/tts') return handleTts(req, ctx);
      return json(404, { error: 'not found' });
    },
  };
}

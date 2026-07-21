// app.mjs — deploy composition: wires the REAL components (SENTI-session verifier + DynamoDB store + ElevenLabs TTS +
// governed gateway) into a Lambda handler. Zero-dep: the deploy INJECTS the externals it owns (a DynamoDB
// DocumentClient, the Ed25519 signing key from KMS/Secrets Manager, a senti `run`ner, fetch).
// Scalar config comes from `env`. Nothing here reaches out on its own — all boundaries are explicit + testable.
import { createGateway } from './handlers.mjs';
import { createHumanMessageClient } from './human-message-client.mjs';
import { createSentiSessionVerifier } from './senti-session-verifier.mjs';
import { createDynamoStore } from './store.mjs';
import { createElevenLabsBackend } from './tts.mjs';
import { createGemmaBackend } from './gemma-backend.mjs';
import { lambdaHandler } from './lambda.mjs';

/**
 * @param {object} env    scalar config (DDB_TABLE, SIGNING_KEY_ID, GATEWAY_PUBLIC_URL, SENTI_API_BASE_URL, TTS_VOICE_ID,
 *                        ELEVENLABS_API_KEY; GEMMA_BASE_URL + GEMMA_MODEL [+ optional GEMMA_API_KEY] to wire /answer+/brief to Gemma)
 * @param {object} deps   injected externals the deploy owns:
 *   { dynamoClient, signingKey, run, knownSessionIdsFor, bundleStore, fetch }
 *   - dynamoClient: the { get, put, delete } async shape createDynamoStore consumes. In prod this is a THIN ADAPTER
 *     (createDynamoClientAdapter in store.mjs) over a v3 @aws-sdk/lib-dynamodb DocumentClient — v3 exposes
 *     .send(new GetCommand(...)), not bare get/put/delete, so the deploy wraps it before injecting here.
 *   - signingKey: Ed25519 private key (KMS/Secrets Manager) for receipts
 *   - fetch: validates SENTI sessions (GET /auth/me) + posts the human write — the gateway holds NO signing secret
 *   - run: a senti writeback runner (bundled sl or a senti API client) — `POST /actions/execute` uses it
 *   - knownSessionIdsFor(humanId): the sessions the human may write to (server-derived authorization)
 *   - bundleStore.listForHuman(humanId, since): signed bundles for `GET /sync`
 */
export function createProdGateway(env = {}, deps = {}) {
  // FAIL BOOT if any production binding is absent (Echo P0). SENTI_API_BASE_URL is load-bearing twice: it's where the
  // gateway VALIDATES the caller's SENTI session (verifyToken -> GET /auth/me) AND where the human write posts.
  const missingEnv = ['DDB_TABLE', 'SIGNING_KEY_ID', 'GATEWAY_PUBLIC_URL', 'SENTI_API_BASE_URL']
    .filter((k) => !env[k]);
  if (missingEnv.length) throw new Error('pocket-gateway prod config missing: ' + missingEnv.join(', '));
  if (!deps.dynamoClient || !deps.signingKey || typeof deps.knownSessionIdsFor !== 'function' || typeof deps.fetch !== 'function') {
    throw new Error('pocket-gateway prod deps missing: dynamoClient + signingKey + knownSessionIdsFor + fetch are required');
  }
  const store = createDynamoStore({ client: deps.dynamoClient, table: env.DDB_TABLE });
  // Pocket-native auth (B3): pocket-gateway is Pocket-PRIVATE — all routes are Pocket-app routes, NO external-MCP/DPoP
  // resource-server surface — so it authenticates the caller's ONE SENTI user-session token by CALLING the api
  // (GET /auth/me). It holds NO signing secret and can never mint a session (the api's HS256 secret never leaves the
  // api). Membership stays the server-derived knownSessionIdsFor(humanId); the SAME token is forwarded to the human write.
  const verifyToken = createSentiSessionVerifier({ fetch: deps.fetch, apiBaseUrl: env.SENTI_API_BASE_URL });
  const ttsBackend = env.ELEVENLABS_API_KEY
    ? createElevenLabsBackend({ apiKey: env.ELEVENLABS_API_KEY, fetch: deps.fetch, defaultVoiceId: env.TTS_VOICE_ID })
    : undefined;

  // Gemma reasoning backend (Carter: "make sure Gemma is used"): light up /answer + /brief via a hosted/local Gemma over
  // an OpenAI-compatible endpoint when GEMMA_BASE_URL is set (key-free Ollama, or AI Studio's OpenAI-compat with a free
  // key). Absent => /answer + /brief stay 501 (reasoning not configured). A deploy-injected deps.reason/deps.brief wins.
  const gemma = env.GEMMA_BASE_URL
    ? createGemmaBackend({ baseUrl: env.GEMMA_BASE_URL, model: env.GEMMA_MODEL, apiKey: env.GEMMA_API_KEY, fetch: deps.fetch })
    : undefined;

  // The HUMAN write door (executeAction humanMessage mode) posts to the api under the caller's OWN bearer — no gateway
  // credential in the path. Constructed HERE (not lazily) so "deps.postHumanMessage is defined" is a BOOT INVARIANT: a
  // prod boot cannot succeed without SENTI_API_BASE_URL + fetch (both required above), which are exactly what builds it,
  // so the humanMessage `undefined dep -> TypeError` gap cannot regress.
  const postHumanMessage = createHumanMessageClient({ fetch: deps.fetch, apiBaseUrl: env.SENTI_API_BASE_URL });

  return createGateway({
    verifyToken,
    store,
    ttsBackend,
    reason: deps.reason || (gemma ? gemma.reason : undefined),   // /answer  (grounding-first; 501 if neither configured)
    brief: deps.brief || (gemma ? gemma.brief : undefined),     // /brief   (grounding-first; 501 if neither configured)
    minConfidence: deps.minConfidence,
    run: deps.run,
    postHumanMessage,
    signingKey: deps.signingKey,
    signingKeyId: env.SIGNING_KEY_ID,
    knownSessionIdsFor: deps.knownSessionIdsFor,
    bundleStore: deps.bundleStore,
    agent: 'claude-pocket-relay',
  });
}

/** The deployed Lambda handler: `export const handler = createLambda(process.env, injectedDeps)`. */
export function createLambda(env, deps) {
  // canonicalBaseUrl pins the DPoP htu to the deploy origin, not an attacker-spoofable Host header (Echo P0).
  return lambdaHandler(createProdGateway(env, deps), { canonicalBaseUrl: env.GATEWAY_PUBLIC_URL });
}

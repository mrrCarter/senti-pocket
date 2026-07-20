// app.mjs — deploy composition: wires the REAL components (AIdenID verifier + DynamoDB store + ElevenLabs TTS +
// governed gateway) into a Lambda handler. Zero-dep: the deploy INJECTS the externals it owns (a DynamoDB
// DocumentClient, the AIdenID JWKS, the Ed25519 signing key from KMS/Secrets Manager, a senti `run`ner, fetch).
// Scalar config comes from `env`. Nothing here reaches out on its own — all boundaries are explicit + testable.
import { createGateway } from './handlers.mjs';
import { createHumanMessageClient } from './human-message-client.mjs';
import { createAidenIdVerifier } from './auth.mjs';
import { createDynamoStore, createStoreReplayGuard } from './store.mjs';
import { createElevenLabsBackend } from './tts.mjs';
import { lambdaHandler } from './lambda.mjs';

/**
 * @param {object} env    scalar config (AIDENID_ISSUER, GATEWAY_AUDIENCE, DDB_TABLE, SIGNING_KEY_ID, TTS_VOICE_ID, REQUIRE_DPOP, ELEVENLABS_API_KEY)
 * @param {object} deps   injected externals the deploy owns:
 *   { dynamoClient, jwks, signingKey, run, knownSessionIdsFor, bundleStore, fetch }
 *   - dynamoClient: @aws-sdk/lib-dynamodb DocumentClient (get/put/delete)
 *   - jwks: AIdenID public keys (fetched + cached from the JWKS endpoint)
 *   - signingKey: Ed25519 private key (KMS/Secrets Manager) for receipts
 *   - run: a senti writeback runner (bundled sl or a senti API client) — `POST /actions/execute` uses it
 *   - knownSessionIdsFor(humanId): the sessions the human may write to (server-derived authorization)
 *   - bundleStore.listForHuman(humanId, since): signed bundles for `GET /sync`
 */
export function createProdGateway(env = {}, deps = {}) {
  // FAIL BOOT if any production binding is absent (Echo P0): all of these gate real security decisions — a missing
  // issuer/audience/resource/siteId would silently SKIP that check in the verifier. Never boot half-configured.
  // SENTI_API_BASE_URL gates the HUMAN write door — required so deps.postHumanMessage is always constructed (see below).
  const missingEnv = ['AIDENID_ISSUER', 'GATEWAY_AUDIENCE', 'GATEWAY_RESOURCE', 'GATEWAY_SITE_ID', 'DDB_TABLE', 'SIGNING_KEY_ID', 'GATEWAY_PUBLIC_URL', 'SENTI_API_BASE_URL']
    .filter((k) => !env[k]);
  if (missingEnv.length) throw new Error('pocket-gateway prod config missing: ' + missingEnv.join(', '));
  if (!deps.dynamoClient || !Array.isArray(deps.jwks) || deps.jwks.length === 0 || !deps.signingKey || typeof deps.knownSessionIdsFor !== 'function' || typeof deps.fetch !== 'function') {
    throw new Error('pocket-gateway prod deps missing: dynamoClient + non-empty jwks + signingKey + knownSessionIdsFor + fetch are required');
  }
  const store = createDynamoStore({ client: deps.dynamoClient, table: env.DDB_TABLE });
  const verifyToken = createAidenIdVerifier({
    jwks: deps.jwks,
    issuer: env.AIDENID_ISSUER,
    audience: env.GATEWAY_AUDIENCE,
    resource: env.GATEWAY_RESOURCE,
    siteId: env.GATEWAY_SITE_ID,
    requireDpop: true,                                    // prod tokens MUST be sender-constrained (DPoP)
    replayGuard: createStoreReplayGuard(store),           // DPoP jti single-use across Lambda instances
  });
  const ttsBackend = env.ELEVENLABS_API_KEY
    ? createElevenLabsBackend({ apiKey: env.ELEVENLABS_API_KEY, fetch: deps.fetch, defaultVoiceId: env.TTS_VOICE_ID })
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

// app.mjs — deploy composition: wires the REAL components (AIdenID verifier + DynamoDB store + ElevenLabs TTS +
// governed gateway) into a Lambda handler. Zero-dep: the deploy INJECTS the externals it owns (a DynamoDB
// DocumentClient, the AIdenID JWKS, the Ed25519 signing key from KMS/Secrets Manager, a senti `run`ner, fetch).
// Scalar config comes from `env`. Nothing here reaches out on its own — all boundaries are explicit + testable.
import { createGateway } from './handlers.mjs';
import { createAidenIdVerifier } from './auth.mjs';
import { createDynamoStore } from './store.mjs';
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
  const verifyToken = createAidenIdVerifier({
    jwks: deps.jwks || [],
    issuer: env.AIDENID_ISSUER,
    audience: env.GATEWAY_AUDIENCE,
    requireDpop: env.REQUIRE_DPOP === 'true',
  });
  const store = createDynamoStore({ client: deps.dynamoClient, table: env.DDB_TABLE });
  const ttsBackend = env.ELEVENLABS_API_KEY
    ? createElevenLabsBackend({ apiKey: env.ELEVENLABS_API_KEY, fetch: deps.fetch, defaultVoiceId: env.TTS_VOICE_ID })
    : undefined;

  return createGateway({
    verifyToken,
    store,
    ttsBackend,
    run: deps.run,
    signingKey: deps.signingKey,
    signingKeyId: env.SIGNING_KEY_ID,
    knownSessionIdsFor: deps.knownSessionIdsFor,
    bundleStore: deps.bundleStore,
    agent: 'claude-pocket-relay',
  });
}

/** The deployed Lambda handler: `export const handler = createLambda(process.env, injectedDeps)`. */
export function createLambda(env, deps) {
  return lambdaHandler(createProdGateway(env, deps));
}

/**
 * Non-secret bindings are generated from wrangler.jsonc into the global `Env`
 * interface by `wrangler types`. Secrets cannot be inferred from checked-in
 * configuration, so they are the only manually declared runtime additions.
 */
export interface WorkerSecretBindings {
  CLOUDFLARE_API_TOKEN: string;
  ROOM_KEY_HMAC_SECRET: string;
  IDENTITY_HMAC_SECRET: string;
}

export type RuntimeEnv = Env & WorkerSecretBindings;

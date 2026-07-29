import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: {
        configPath: "./wrangler.jsonc",
      },
      miniflare: {
        bindings: {
          IDENTITY_HMAC_SECRET:
            "identity-test-secret-at-least-thirty-two-characters",
        },
      },
    }),
  ],
});

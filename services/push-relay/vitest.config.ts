import { generateKeyPairSync, randomBytes } from "node:crypto";

import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// Throwaway keys per run: a P-256 key standing in for the APNs .p8 (tests verify the JWT with
// its public half) and a capability key. Nothing secret is committed.
const apns = generateKeyPairSync("ec", { namedCurve: "P-256" });

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          APNS_PRIVATE_KEY: apns.privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
          TEST_APNS_PUBLIC_KEY: apns.publicKey.export({ type: "spki", format: "pem" }).toString(),
          PUSH_CAP_KEY: randomBytes(32).toString("base64url"),
          PUSH_CAP_KEY_PREVIOUS: randomBytes(32).toString("base64url"),
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
    // Several tests drive a bucket to its limit request by request; slow on a busy machine.
    testTimeout: 60_000,
  },
});

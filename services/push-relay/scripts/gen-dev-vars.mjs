#!/usr/bin/env node
// Writes `.dev.vars` (gitignored) for `npm run dev`: a throwaway P-256 key in place of the APNs
// .p8 (the fake APNs accepts any JWT) and a random capability key. Never use these in
// production; there the secrets are set with `wrangler secret put` (docs/PUSH.md).
//
// With `--cap-key-only`, prints a fresh PUSH_CAP_KEY value instead (for production setup).
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { existsSync, writeFileSync } from "node:fs";

const capKey = randomBytes(32).toString("base64url");
if (process.argv.includes("--cap-key-only")) {
  console.log(capKey);
  process.exit(0);
}
if (existsSync(".dev.vars") && !process.argv.includes("--force")) {
  console.error(".dev.vars exists; pass --force to replace it");
  process.exit(1);
}
const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
writeFileSync(
  ".dev.vars",
  `APNS_PRIVATE_KEY="${pem.trim().replace(/\n/g, "\\n")}"\nPUSH_CAP_KEY="${capKey}"\n`,
  { mode: 0o600 },
);
console.log("wrote .dev.vars");

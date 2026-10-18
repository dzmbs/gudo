import type { RateLimiter } from "./limiter";

/** Bindings. Secrets (`wrangler secret put`) are marked; nothing secret is in wrangler.jsonc. */
export interface Env {
  /** Apple Developer team id (10 chars). */
  APNS_TEAM_ID: string;
  /** Key id of the APNs auth key (.p8). */
  APNS_KEY_ID: string;
  /** Secret: the .p8 file's contents (PKCS#8 PEM, P-256). */
  APNS_PRIVATE_KEY: string;
  /** The app's bundle id; Live Activities use `<topic>.push-type.liveactivity`. */
  APNS_TOPIC: string;
  /**
   * Overrides the APNs origin (`https://api.push.apple.com` / `https://api.sandbox.push.apple.com`),
   * e.g. `http://127.0.0.1:8790` for the fake APNs in local development.
   */
  APNS_ORIGIN?: string;
  /** Secret: 32 random bytes, base64url: seals push capabilities. */
  PUSH_CAP_KEY: string;
  /** Secret, optional: the previous cap key during a rotation (still opens old caps). */
  PUSH_CAP_KEY_PREVIOUS?: string;
  /** Days a push capability stays valid (default 180). */
  CAP_TTL_DAYS?: string;
  /** Per-daemon and per-IP rate limits, and per-daemon nonce memory. */
  LIMITER: DurableObjectNamespace<RateLimiter>;
}

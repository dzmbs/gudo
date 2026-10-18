/**
 *
 * A capability is `v1.<base64url(iv || AES-256-GCM(PUSH_CAP_KEY, json))>`, where the JSON names
 * the APNs token, its environment, the one daemon allowed to use it, the push kind and an
 * expiry. Only the relay can open it; the daemon stores it as an opaque string and never sees
 * the APNs token. Revocation is by expiry and key rotation (`PUSH_CAP_KEY_PREVIOUS`).
 */
import { b64url, concat, unb64url, utf8 } from "./encoding";

/** APNs environment of a device token (development builds use the sandbox). */
export type ApnsEnv = "production" | "sandbox";

/** What a capability lets its daemon push. */
export type CapKind = "alert" | "activity";

export interface Cap {
  /** APNs device token (or Live Activity token), hex. */
  t: string;
  e: ApnsEnv;
  /** The daemon's Ed25519 key, hex. */
  d: string;
  k: CapKind;
  /** Expiry, Unix seconds. */
  x: number;
}

const PREFIX = "v1.";
const AAD = utf8.encode("push-cap/v1");

async function aesKey(secret: string): Promise<CryptoKey> {
  const raw = unb64url(secret);
  if (!raw || raw.length !== 32) throw new Error("PUSH_CAP_KEY must be 32 bytes, base64url");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function sealCap(secret: string, cap: Cap): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: AAD },
    await aesKey(secret),
    utf8.encode(JSON.stringify(cap)),
  );
  return PREFIX + b64url(concat(iv, new Uint8Array(ct)));
}

/** Opens a capability with the current key, then the previous one; `null` if neither opens it. */
export async function openCap(
  text: string,
  secrets: (string | undefined)[],
): Promise<Cap | null> {
  if (!text.startsWith(PREFIX)) return null;
  const raw = unb64url(text.slice(PREFIX.length));
  if (!raw || raw.length < 12 + 16) return null;
  for (const secret of secrets) {
    if (!secret) continue;
    try {
      const pt = await crypto.subtle.decrypt(
        { name: "AES-GCM", iv: raw.slice(0, 12), additionalData: AAD },
        await aesKey(secret),
        raw.slice(12),
      );
      return JSON.parse(new TextDecoder().decode(pt)) as Cap;
    } catch {
      // Try the next key.
    }
  }
  return null;
}

/**
 * The daemon's push request (crates/push `RelayRequest`) and its signature.
 *
 * The body is JSON; the `x-push-signature` header is base64url Ed25519 over
 * `"push-relay/v1\0" || body`, by the key named in `body.daemon` (the daemon's iroh key).
 */
import { concat, unb64url, unhex, utf8 } from "./encoding";

export type Category = "approval" | "blocked" | "done" | "command";
export type PushType = "alert" | "live_activity";
export type ActivityEvent = "start" | "update" | "end";

export interface RelayRequest {
  v: number;
  daemon: string;
  cap: string;
  push_type: PushType;
  category?: Category;
  collapse?: string;
  sealed: string;
  ts: number;
  nonce: string;
  event?: ActivityEvent;
  stale?: number;
  dismiss?: number;
  urgent?: boolean;
}

export const SIGNATURE_HEADER = "x-push-signature";
const DOMAIN = utf8.encode("push-relay/v1\0");
/** Sealed payloads above this cannot fit APNs' 4 KiB with our envelope. */
export const MAX_SEALED = 3500;

const CATEGORIES = new Set(["approval", "blocked", "done", "command"]);
const EVENTS = new Set(["start", "update", "end"]);

/** Parses and shape-checks a body; returns an error message for a malformed one. */
export function parseRequest(body: Uint8Array): RelayRequest | string {
  let r: RelayRequest;
  try {
    r = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return "body is not JSON";
  }
  if (typeof r !== "object" || r === null || Array.isArray(r)) return "body is not an object";
  if (r.v !== 1) return "unsupported version";
  if (typeof r.daemon !== "string" || !unhex(r.daemon, 32)) return "bad daemon key";
  if (typeof r.cap !== "string" || r.cap.length > 4096) return "bad cap";
  if (typeof r.sealed !== "string" || !unb64url(r.sealed)) return "bad sealed payload";
  if (r.sealed.length > MAX_SEALED) return "sealed payload too large";
  if (!Number.isSafeInteger(r.ts) || r.ts < 0) return "bad ts";
  if (typeof r.nonce !== "string" || !/^[0-9a-f]{16,64}$/.test(r.nonce)) return "bad nonce";
  // Goes into an HTTP header: the daemon's hex digest, never free text.
  if (r.collapse !== undefined && (typeof r.collapse !== "string" || !/^[0-9a-f]{1,64}$/.test(r.collapse)))
    return "bad collapse id";
  if (r.push_type === "alert") {
    if (typeof r.category !== "string" || !CATEGORIES.has(r.category)) return "alerts need a category";
  } else if (r.push_type === "live_activity") {
    if (typeof r.event !== "string" || !EVENTS.has(r.event)) return "live activities need an event";
  } else {
    return "bad push_type";
  }
  for (const k of ["stale", "dismiss"] as const) {
    const t = r[k];
    if (t !== undefined && (!Number.isSafeInteger(t) || t < 0)) return `bad ${k}`;
  }
  if (r.urgent !== undefined && typeof r.urgent !== "boolean") return "bad urgent";
  return r;
}

/** Verifies the daemon's Ed25519 signature over the exact body bytes. */
export async function verifySignature(
  daemonHex: string,
  body: Uint8Array,
  signature: string | null,
): Promise<boolean> {
  const sig = signature ? unb64url(signature) : null;
  const pub = unhex(daemonHex, 32);
  if (!sig || sig.length !== 64 || !pub) return false;
  try {
    const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, sig, concat(DOMAIN, body));
  } catch {
    return false;
  }
}

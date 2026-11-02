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
  let request: RelayRequest;
  try {
    request = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return "body is not JSON";
  }
  if (typeof request !== "object" || request === null || Array.isArray(request)) return "body is not an object";
  if (request.v !== 1) return "unsupported version";
  if (typeof request.daemon !== "string" || !unhex(request.daemon, 32)) return "bad daemon key";
  if (typeof request.cap !== "string" || request.cap.length > 4096) return "bad cap";
  if (typeof request.sealed !== "string" || !unb64url(request.sealed)) return "bad sealed payload";
  if (request.sealed.length > MAX_SEALED) return "sealed payload too large";
  if (!Number.isSafeInteger(request.ts) || request.ts < 0) return "bad ts";
  if (typeof request.nonce !== "string" || !/^[0-9a-f]{16,64}$/.test(request.nonce)) return "bad nonce";
  // Goes into an HTTP header: the daemon's hex digest, never free text.
  if (request.collapse !== undefined && (typeof request.collapse !== "string" || !/^[0-9a-f]{1,64}$/.test(request.collapse)))
    return "bad collapse id";
  if (request.push_type === "alert") {
    if (typeof request.category !== "string" || !CATEGORIES.has(request.category)) return "alerts need a category";
  } else if (request.push_type === "live_activity") {
    if (typeof request.event !== "string" || !EVENTS.has(request.event)) return "live activities need an event";
  } else {
    return "bad push_type";
  }
  for (const field of ["stale", "dismiss"] as const) {
    const seconds = request[field];
    if (seconds !== undefined && (!Number.isSafeInteger(seconds) || seconds < 0)) return `bad ${field}`;
  }
  if (request.urgent !== undefined && typeof request.urgent !== "boolean") return "bad urgent";
  return request;
}

/** Verifies the daemon's Ed25519 signature over the exact body bytes. */
export async function verifySignature(
  daemonHex: string,
  body: Uint8Array,
  signature: string | null,
): Promise<boolean> {
  const signatureBytes = signature ? unb64url(signature) : null;
  const publicKey = unhex(daemonHex, 32);
  if (!signatureBytes || signatureBytes.length !== 64 || !publicKey) return false;
  try {
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "Ed25519" }, key, signatureBytes, concat(DOMAIN, body));
  } catch {
    return false;
  }
}

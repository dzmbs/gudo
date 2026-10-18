/**
 * APNs over HTTP/2 with token-based (.p8) authentication.
 *
 * Workers' `fetch` negotiates HTTP/2 with api.push.apple.com by itself. The provider JWT (ES256,
 * `kid` = key id, `iss` = team id) is cached per isolate and renewed after 40 minutes: Apple
 * rejects tokens older than an hour and throttles renewals more often than every 20 minutes
 * (`TooManyProviderTokenUpdates`).
 */
import type { Cap } from "./cap";
import type { Env } from "./env";
import { b64url, utf8 } from "./encoding";
import type { Category, RelayRequest } from "./request";

const JWT_LIFETIME_MS = 40 * 60 * 1000;
let cached: { jwt: string; at: number; keyId: string } | null = null;

/** Drops the cached JWT (after APNs rejects it). */
export function resetJwt(): void {
  cached = null;
}

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export async function providerJwt(env: Env, now = Date.now()): Promise<string> {
  if (cached && cached.keyId === env.APNS_KEY_ID && now - cached.at < JWT_LIFETIME_MS) {
    return cached.jwt;
  }
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(env.APNS_PRIVATE_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64url(utf8.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(
    utf8.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })),
  );
  const input = `${header}.${claims}`;
  // WebCrypto's ECDSA signature is r || s, which is exactly JWS's ES256 format.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8.encode(input));
  const jwt = `${input}.${b64url(new Uint8Array(sig))}`;
  cached = { jwt, at: now, keyId: env.APNS_KEY_ID };
  return jwt;
}

/** What the relay shows if the extension cannot decrypt (it only knows the category). */
const PLACEHOLDER: Record<Category, { title: string; body: string }> = {
  approval: { title: "Approval needed", body: "An agent is waiting for you." },
  blocked: { title: "Agent waiting", body: "An agent needs your input." },
  done: { title: "Agent finished", body: "Open to see the result." },
  command: { title: "Command finished", body: "Open to see the output." },
};

/** `UNNotificationCategory` ids (crates/push `Category::apns_category`). */
export const APNS_CATEGORY: Record<Category, string> = {
  approval: "AGENT_APPROVAL",
  blocked: "AGENT_BLOCKED",
  done: "AGENT_DONE",
  command: "COMMAND_DONE",
};

/** The `attributes-type` of the agents Live Activity (the app's ActivityAttributes struct). */
export const ACTIVITY_ATTRIBUTES_TYPE = "AgentsActivityAttributes";

export interface ApnsRequest {
  url: string;
  headers: Record<string, string>;
  body: string;
}

/** Builds the APNs request for a verified relay request and its opened capability. */
export function buildApnsRequest(env: Env, cap: Cap, req: RelayRequest, nowMs = Date.now()): ApnsRequest {
  const origin =
    env.APNS_ORIGIN ||
    (cap.e === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com");
  const now = Math.floor(nowMs / 1000);
  const headers: Record<string, string> = {};
  let payload: unknown;
  if (req.push_type === "alert") {
    const category = req.category!;
    const urgent = category === "approval" || category === "blocked";
    headers["apns-push-type"] = "alert";
    headers["apns-topic"] = env.APNS_TOPIC;
    headers["apns-priority"] = urgent ? "10" : "5";
    // An approval is pointless after its action token expires (an hour).
    headers["apns-expiration"] = String(now + 3600);
    payload = {
      aps: {
        alert: PLACEHOLDER[category],
        "mutable-content": 1,
        category: APNS_CATEGORY[category],
        sound: "default",
        "interruption-level": urgent ? "time-sensitive" : "active",
      },
      s: req.sealed,
      v: 1,
    };
  } else {
    headers["apns-push-type"] = "liveactivity";
    headers["apns-topic"] = `${env.APNS_TOPIC}.push-type.liveactivity`;
    headers["apns-priority"] = req.urgent ? "10" : "5";
    const aps: Record<string, unknown> = {
      timestamp: now,
      event: req.event,
      // The widget decrypts `s` while rendering (docs/PUSH.md, Live Activities).
      "content-state": { s: req.sealed, v: 1 },
    };
    if (req.stale !== undefined) aps["stale-date"] = req.stale;
    if (req.dismiss !== undefined) aps["dismissal-date"] = req.dismiss;
    if (req.event === "start") {
      aps["attributes-type"] = ACTIVITY_ATTRIBUTES_TYPE;
      aps.attributes = { v: 1 };
      aps.alert = { title: "Agents", body: "Your agents are running." };
    }
    payload = { aps };
  }
  if (req.collapse) headers["apns-collapse-id"] = req.collapse;
  return {
    url: `${origin}/3/device/${cap.t}`,
    headers,
    body: JSON.stringify(payload),
  };
}

/** What APNs said, reduced to what the daemon needs. */
export type ApnsOutcome =
  | { kind: "sent"; id: string | null }
  | { kind: "gone"; reason: string }
  | { kind: "retry"; status: number; reason: string; retryAfter?: string }
  | { kind: "rejected"; status: number; reason: string };

export async function sendToApns(env: Env, req: ApnsRequest): Promise<ApnsOutcome> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const jwt = await providerJwt(env);
    const res = await fetch(req.url, {
      method: "POST",
      headers: { ...req.headers, authorization: `bearer ${jwt}`, "content-type": "application/json" },
      body: req.body,
    });
    if (res.ok) return { kind: "sent", id: res.headers.get("apns-id") };
    let reason = "";
    try {
      reason = ((await res.json()) as { reason?: string }).reason ?? "";
    } catch {
      // Not JSON.
    }
    // A stale or revoked provider token: mint a new one once.
    if (res.status === 403 && reason === "ExpiredProviderToken" && attempt === 0) {
      resetJwt();
      continue;
    }
    if (
      res.status === 410 ||
      (res.status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic"))
    ) {
      return { kind: "gone", reason };
    }
    if (res.status === 429 || res.status >= 500) {
      return {
        kind: "retry",
        status: res.status,
        reason,
        retryAfter: res.headers.get("retry-after") ?? undefined,
      };
    }
    return { kind: "rejected", status: res.status, reason };
  }
  return { kind: "retry", status: 403, reason: "ExpiredProviderToken" };
}

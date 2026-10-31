/**
 * The push relay (ARCHITECTURE D16, docs/PUSH.md): one Cloudflare Worker between host daemons
 * and APNs. It holds the APNs key and learns only an APNs token (inside a capability it
 * issued), ciphertext, timing and a coarse category.
 *
 * - `POST /v1/register` — the app trades its APNs token for a capability bound to one daemon.
 * - `POST /v1/push` — a daemon sends a sealed notification, signed with its iroh key.
 * - `GET /healthz`.
 */
import { buildApnsRequest, sendToApns } from "./apns";
import { type ApnsEnv, type Cap, type CapKind, openCap, sealCap } from "./cap";
import { hex, unhex, utf8 } from "./encoding";
import type { Env } from "./env";
import {
  ACTIVITY_TOKEN_BUCKET,
  ALERT_TOKEN_BUCKET,
  DAEMON_BUCKET,
  NONCE_TTL_MS,
  REGISTER_BUCKET,
  type Bucket,
  type Verdict,
} from "./limiter";
import { SIGNATURE_HEADER, parseRequest, verifySignature } from "./request";

export { RateLimiter } from "./limiter";

export const MAX_BODY = 8 * 1024;

/** An API that browsers have no business reading or framing. */
const SECURITY_HEADERS: Record<string, string> = {
  "cache-control": "no-store",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
  "referrer-policy": "no-referrer",
  "strict-transport-security": "max-age=31536000",
  "x-content-type-options": "nosniff",
  "x-frame-options": "DENY",
};

function respond(status: number, body: string, headers: Record<string, string> = {}): Response {
  return new Response(body, { status, headers: { ...SECURITY_HEADERS, ...headers } });
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return respond(status, JSON.stringify(body), { "content-type": "application/json", ...headers });
}

function error(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json(status, { error: message }, headers);
}

function limited(verdict: Verdict, message: string): Response {
  return error(429, message, {
    "retry-after": String(verdict.ok || verdict.reason !== "rate" ? 60 : verdict.retryAfter),
  });
}

async function limit(
  env: Env,
  key: string,
  bucket: Bucket,
  nonce: string | null = null,
  nonceUntil?: number,
): Promise<Verdict> {
  const stub = env.LIMITER.get(env.LIMITER.idFromName(key));
  return stub.take(bucket, nonce, Date.now(), nonceUntil);
}

/** Reads at most [`MAX_BODY`] bytes; `null` for a larger body, without buffering it. */
async function readBody(request: Request): Promise<Uint8Array | null> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY) return null;
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > MAX_BODY) {
      await reader.cancel();
      return null;
    }
    parts.push(value);
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/**
 * The rate-limit key of a client address: IPv4 as is (also IPv4-mapped, which would otherwise
 * all share `::/64`), IPv6 by its /64 (one subscriber gets a whole /64, so per-address limits
 * would not hold).
 */
export function addressKey(ip: string): string {
  if (!ip.includes(":")) return ip;
  const mapped = /^(?:::|(?:0{1,4}:){5})ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(ip);
  if (mapped) return mapped[1];
  const [head, tail = ""] = ip.toLowerCase().split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = ip.includes("::")
    ? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right]
    : left;
  return `${groups
    .slice(0, 4)
    .map((g) => g.replace(/^0+(?=.)/, ""))
    .join(":")}::/64`;
}

/**
 * Durable Object name of an APNs token's bucket; hashed so the token never names an object.
 * One per kind: the alert and activity buckets refill at different rates and sharing one
 * state would let activity pushes refill the alert budget.
 */
async function tokenKey(cap: Cap): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", utf8.encode(`${cap.k}:${cap.e}:${cap.t}`));
  return `token:${hex(new Uint8Array(digest))}`;
}

interface RegisterBody {
  /** APNs device token (or Live Activity push token), hex. */
  token: string;
  env: ApnsEnv;
  /** The daemon the capability is for (its iroh endpoint id), hex. */
  daemon: string;
  /** `alert` (default) or `activity`. */
  kind?: CapKind;
}

async function register(request: Request, env: Env): Promise<Response> {
  const ip = request.headers.get("cf-connecting-ip") ?? "local";
  const verdict = await limit(env, `ip:${addressKey(ip)}`, REGISTER_BUCKET);
  if (!verdict.ok) return limited(verdict, "too many registrations");
  const raw = await readBody(request);
  if (!raw) return error(413, "body too large");
  let body: RegisterBody;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return error(400, "body is not JSON");
  }
  if (typeof body !== "object" || body === null || Array.isArray(body))
    return error(400, "body is not an object");
  if (typeof body.token !== "string" || !/^(?:[0-9a-fA-F]{2}){8,200}$/.test(body.token))
    return error(400, "bad token");
  if (body.env !== "production" && body.env !== "sandbox") return error(400, "bad env");
  if (typeof body.daemon !== "string" || !unhex(body.daemon, 32)) return error(400, "bad daemon key");
  const kind = body.kind ?? "alert";
  if (kind !== "alert" && kind !== "activity") return error(400, "bad kind");
  const days = Number(env.CAP_TTL_DAYS ?? "180");
  const expires = Math.floor(Date.now() / 1000) + days * 86400;
  const cap = await sealCap(env.PUSH_CAP_KEY, {
    t: body.token.toLowerCase(),
    e: body.env,
    d: body.daemon.toLowerCase(),
    k: kind,
    x: expires,
  });
  return json(200, { cap, expires });
}

async function push(request: Request, env: Env): Promise<Response> {
  const body = await readBody(request);
  if (!body) return error(413, "body too large");
  const req = parseRequest(body);
  if (typeof req === "string") return error(400, req);
  if (!(await verifySignature(req.daemon, body, request.headers.get(SIGNATURE_HEADER)))) {
    return error(401, "bad signature");
  }
  if (Math.abs(Date.now() - req.ts) > NONCE_TTL_MS) return error(401, "stale request");
  const cap = await openCap(req.cap, [env.PUSH_CAP_KEY, env.PUSH_CAP_KEY_PREVIOUS]);
  if (!cap) return error(403, "bad capability");
  if (cap.d !== req.daemon.toLowerCase()) return error(403, "capability is for another daemon");
  if (cap.x * 1000 < Date.now()) return error(410, "capability expired; the app re-registers");
  const wanted: CapKind = req.push_type === "alert" ? "alert" : "activity";
  if (cap.k !== wanted) return error(403, `capability is not for ${req.push_type}`);

  // The nonce is remembered for as long as `ts` passes the skew check, so a request signed
  // with a future `ts` cannot be replayed once the nonce would otherwise be forgotten.
  const daemon = await limit(
    env,
    `daemon:${req.daemon.toLowerCase()}`,
    DAEMON_BUCKET,
    req.nonce,
    req.ts + NONCE_TTL_MS,
  );
  if (!daemon.ok) {
    return daemon.reason === "replay" ? error(409, "replayed request") : limited(daemon, "rate limited");
  }
  const device = await limit(
    env,
    await tokenKey(cap),
    cap.k === "alert" ? ALERT_TOKEN_BUCKET : ACTIVITY_TOKEN_BUCKET,
  );
  if (!device.ok) return limited(device, "too many pushes to this device");

  const outcome = await sendToApns(env, buildApnsRequest(env, cap, req));
  switch (outcome.kind) {
    case "sent":
      return json(200, { id: outcome.id });
    case "gone":
      // The daemon drops the registration; the app re-registers with a fresh token.
      return error(410, `device token is no longer valid (${outcome.reason})`);
    case "retry":
      return error(outcome.status === 429 ? 429 : 502, `APNs ${outcome.status} ${outcome.reason}`, {
        "retry-after": outcome.retryAfter ?? "5",
      });
    case "rejected":
      return error(422, `APNs refused the push: ${outcome.status} ${outcome.reason}`);
  }
}

async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  if (request.method === "GET" && pathname === "/healthz") return respond(200, "ok");
  if (request.method !== "POST") return error(405, "method not allowed", { allow: "POST" });
  switch (pathname) {
    case "/v1/register":
      return register(request, env);
    case "/v1/push":
      return push(request, env);
    default:
      return error(404, "not found");
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch {
      // No exception text: it could carry configuration or request details.
      return error(500, "internal error");
    }
  },
} satisfies ExportedHandler<Env>;

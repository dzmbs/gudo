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
import { type ApnsEnv, type CapKind, openCap, sealCap } from "./cap";
import { unhex } from "./encoding";
import type { Env } from "./env";
import { DAEMON_BUCKET, NONCE_TTL_MS, REGISTER_BUCKET, type Bucket, type Verdict } from "./limiter";
import { SIGNATURE_HEADER, parseRequest, verifySignature } from "./request";

export { RateLimiter } from "./limiter";

const MAX_BODY = 8 * 1024;

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

function error(status: number, message: string, headers: Record<string, string> = {}): Response {
  return json(status, { error: message }, headers);
}

async function limit(env: Env, key: string, bucket: Bucket, nonce: string | null): Promise<Verdict> {
  const stub = env.LIMITER.get(env.LIMITER.idFromName(key));
  return stub.take(bucket, nonce, Date.now());
}

async function readBody(request: Request): Promise<Uint8Array | null> {
  const body = new Uint8Array(await request.arrayBuffer());
  return body.length > MAX_BODY ? null : body;
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
  const verdict = await limit(env, `ip:${ip}`, REGISTER_BUCKET, null);
  if (!verdict.ok) {
    return error(429, "too many registrations", {
      "retry-after": String(verdict.reason === "rate" ? verdict.retryAfter : 60),
    });
  }
  const raw = await readBody(request);
  if (!raw) return error(413, "body too large");
  let body: RegisterBody;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return error(400, "body is not JSON");
  }
  if (typeof body.token !== "string" || !/^[0-9a-fA-F]{16,400}$/.test(body.token))
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

  const verdict = await limit(env, `daemon:${req.daemon.toLowerCase()}`, DAEMON_BUCKET, req.nonce);
  if (!verdict.ok) {
    return verdict.reason === "replay"
      ? error(409, "replayed request")
      : error(429, "rate limited", { "retry-after": String(verdict.retryAfter) });
  }

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/healthz") return new Response("ok");
    if (request.method !== "POST") return error(405, "method not allowed");
    switch (pathname) {
      case "/v1/register":
        return register(request, env);
      case "/v1/push":
        return push(request, env);
      default:
        return error(404, "not found");
    }
  },
} satisfies ExportedHandler<Env>;

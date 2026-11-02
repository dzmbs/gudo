import { runDurableObjectAlarm } from "cloudflare:test";
import { env as cfEnv, exports as cfExports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import vectors from "../../../crates/push/tests/vectors/push-v1.json";
import { APPROVAL_TTL_S, buildApnsRequest, providerJwt, resetJwt } from "../src/apns";
import { openCap, sealCap } from "../src/cap";
import { b64url, concat, hex, unb64url, utf8 } from "../src/encoding";
import { MAX_BODY, addressKey } from "../src/index";
import { ALERT_TOKEN_BUCKET, DAEMON_BUCKET } from "../src/limiter";
import type { Env } from "../src/env";
import { type RelayRequest, parseRequest, verifySignature } from "../src/request";

/** The bindings, as wrangler.jsonc and vitest.config.ts define them. */
const env = cfEnv as unknown as Env & { TEST_APNS_PUBLIC_KEY: string };
const worker = (cfExports as unknown as { default: { fetch(request: Request): Promise<Response> } })
  .default;

/** A fresh device per test: rate-limit state outlives a test. */
let TOKEN = "";

/** A stand-in daemon: an Ed25519 key, like the daemon's iroh key. */
async function daemon() {
  const keys = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const raw = new Uint8Array(
    (await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer,
  );
  return { id: hex(raw), key: keys.privateKey };
}
type Daemon = Awaited<ReturnType<typeof daemon>>;

function nonce(): string {
  return hex(crypto.getRandomValues(new Uint8Array(16)));
}

async function call(path: string, init: RequestInit = {}): Promise<Response> {
  return worker.fetch(new Request(`https://push.test${path}`, init));
}

async function register(
  host: Daemon,
  extra: Record<string, unknown> = {},
): Promise<{ cap: string; expires: number }> {
  // A fresh client address each time, so tests stay clear of the per-address limit.
  const octets = crypto.getRandomValues(new Uint8Array(3));
  const response = await call("/v1/register", {
    method: "POST",
    headers: { "cf-connecting-ip": `10.${octets.join(".")}` },
    body: JSON.stringify({ token: TOKEN, env: "production", daemon: host.id, ...extra }),
  });
  expect(response.status).toBe(200);
  return response.json();
}

async function signed(host: Daemon, fields: Partial<RelayRequest>): Promise<RequestInit> {
  const body = utf8.encode(
    JSON.stringify({
      v: 1,
      daemon: host.id,
      push_type: "alert",
      category: "approval",
      collapse: "c0ffee".repeat(5) + "00",
      sealed: b64url(crypto.getRandomValues(new Uint8Array(200))),
      ts: Date.now(),
      nonce: nonce(),
      ...fields,
    }),
  );
  const signature = await crypto.subtle.sign(
    { name: "Ed25519" },
    host.key,
    concat(utf8.encode("push-relay/v1\0"), body),
  );
  return {
    method: "POST",
    body,
    headers: { "x-push-signature": b64url(new Uint8Array(signature)) },
  };
}

interface ApnsCall {
  url: string;
  headers: Headers;
  body: any;
}

let apnsCalls: ApnsCall[];
let apnsReply: () => Response;

beforeEach(() => {
  TOKEN = hex(crypto.getRandomValues(new Uint8Array(32)));
  resetJwt();
  apnsCalls = [];
  apnsReply = () => new Response(null, { status: 200, headers: { "apns-id": "id-1" } });
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input as RequestInfo, init);
    apnsCalls.push({
      url: request.url,
      headers: request.headers,
      body: JSON.parse(await request.text()),
    });
    return apnsReply();
  });
});

afterEach(() => {
  vi.restoreAllMocks();
});

async function verifyJwt(jwt: string): Promise<{ header: any; claims: any }> {
  const [encodedHeader, encodedClaims, signature] = jwt.split(".");
  const der = Uint8Array.from(
    atob(env.TEST_APNS_PUBLIC_KEY.replace(/-----[^-]+-----|\s/g, "")),
    (ch) => ch.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "spki",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    unb64url(signature)!,
    utf8.encode(`${encodedHeader}.${encodedClaims}`),
  );
  expect(ok).toBe(true);
  const decode = (part: string) => JSON.parse(new TextDecoder().decode(unb64url(part)!));
  return { header: decode(encodedHeader), claims: decode(encodedClaims) };
}

describe("push relay", () => {
  it("answers health checks and refuses unknown routes", async () => {
    expect(await (await call("/healthz")).text()).toBe("ok");
    expect((await call("/nope", { method: "POST" })).status).toBe(404);
    expect((await call("/v1/push")).status).toBe(405);
  });

  it("forwards a signed approval to APNs as a mutable, time-sensitive alert", async () => {
    const host = await daemon();
    const { cap, expires } = await register(host);
    expect(cap.startsWith("v1.")).toBe(true);
    expect(cap).not.toContain(TOKEN);
    expect(expires * 1000).toBeGreaterThan(Date.now() + 170 * 86400 * 1000);

    const init = await signed(host, { cap });
    const response = await call("/v1/push", init);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: "id-1" });

    expect(apnsCalls).toHaveLength(1);
    const [apns] = apnsCalls;
    expect(apns.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
    expect(apns.headers.get("apns-push-type")).toBe("alert");
    expect(apns.headers.get("apns-topic")).toBe("dev.gudo.app");
    expect(apns.headers.get("apns-priority")).toBe("10");
    expect(apns.headers.get("apns-collapse-id")).toBe("c0ffee".repeat(5) + "00");
    const sent = JSON.parse(new TextDecoder().decode(init.body as Uint8Array));
    expect(apns.body).toEqual({
      aps: {
        alert: { title: "Approval needed", body: "An agent is waiting for you." },
        "mutable-content": 1,
        category: "AGENT_APPROVAL",
        sound: "default",
        "interruption-level": "time-sensitive",
      },
      s: sent.sealed,
      v: 1,
    });

    const { header, claims } = await verifyJwt(apns.headers.get("authorization")!.slice(7));
    expect(header).toEqual({ alg: "ES256", kid: env.APNS_KEY_ID });
    expect(claims.iss).toBe(env.APNS_TEAM_ID);
  });

  it("uses the sandbox for development tokens and a low priority for done", async () => {
    const host = await daemon();
    const { cap } = await register(host, { env: "sandbox" });
    const response = await call("/v1/push", await signed(host, { cap, category: "done" }));
    expect(response.status).toBe(200);
    expect(apnsCalls[0].url).toBe(`https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
    expect(apnsCalls[0].headers.get("apns-priority")).toBe("5");
    expect(apnsCalls[0].body.aps.category).toBe("AGENT_DONE");
    expect(apnsCalls[0].body.aps["interruption-level"]).toBe("active");
  });

  it("refuses bad signatures, stale requests, replays and foreign capabilities", async () => {
    const host = await daemon();
    const other = await daemon();
    const { cap } = await register(host);

    const forged = await signed(other, { cap });
    const forgedBody = JSON.parse(new TextDecoder().decode(forged.body as Uint8Array));
    forgedBody.daemon = host.id; // claims to be host, signed by other
    const forgedResponse = await call("/v1/push", { ...forged, body: JSON.stringify(forgedBody) });
    expect(forgedResponse.status).toBe(401);

    const stale = await call("/v1/push", await signed(host, { cap, ts: Date.now() - 10 * 60 * 1000 }));
    expect(stale.status).toBe(401);

    const once = await signed(host, { cap });
    expect((await call("/v1/push", once)).status).toBe(200);
    expect((await call("/v1/push", once)).status).toBe(409);

    // other's own valid signature, but host's capability.
    expect((await call("/v1/push", await signed(other, { cap }))).status).toBe(403);
    // A garbled capability.
    expect((await call("/v1/push", await signed(host, { cap: cap.slice(0, -4) + "AAAA" }))).status).toBe(
      403,
    );
    // An alert capability cannot start a Live Activity.
    const liveActivity = await signed(host, { cap, push_type: "live_activity", event: "update", category: undefined });
    expect((await call("/v1/push", liveActivity)).status).toBe(403);
    expect(apnsCalls).toHaveLength(1);
  });

  it("rejects malformed requests", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    expect((await call("/v1/push", { method: "POST", body: "{" })).status).toBe(400);
    for (const bad of [
      { category: "nope" },
      { push_type: "fax" },
      { nonce: "zz" },
      { sealed: "!!" },
      { sealed: "A".repeat(4000) },
      { daemon: "00" },
    ] as Partial<RelayRequest>[]) {
      expect((await call("/v1/push", await signed(host, { cap, ...bad }))).status, JSON.stringify(bad)).toBe(400);
    }
    expect(
      (await call("/v1/register", { method: "POST", body: JSON.stringify({ token: "xyz" }) })).status,
    ).toBe(400);
  });

  it("rate-limits each daemon", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    let limited: Response | undefined;
    for (let i = 0; i < DAEMON_BUCKET.capacity + 1; i++) {
      const response = await call("/v1/push", await signed(host, { cap }));
      if (response.status === 429) {
        limited = response;
        break;
      }
      expect(response.status).toBe(200);
    }
    expect(limited, "the bucket ran out").toBeDefined();
    expect(Number(limited!.headers.get("retry-after"))).toBeGreaterThan(0);
    // Another daemon (pushing to another device) is unaffected.
    const otherHost = await daemon();
    const { cap: otherCap } = await register(otherHost, { token: "b2".repeat(32) });
    expect((await call("/v1/push", await signed(otherHost, { cap: otherCap }))).status).toBe(200);
  });

  it("maps APNs answers for the daemon", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    apnsReply = () => Response.json({ reason: "Unregistered" }, { status: 410 });
    expect((await call("/v1/push", await signed(host, { cap }))).status).toBe(410);
    apnsReply = () => Response.json({ reason: "BadDeviceToken" }, { status: 400 });
    expect((await call("/v1/push", await signed(host, { cap }))).status).toBe(410);
    apnsReply = () => Response.json({ reason: "InternalServerError" }, { status: 500 });
    const busy = await call("/v1/push", await signed(host, { cap }));
    expect(busy.status).toBe(502);
    expect(busy.headers.get("retry-after")).toBe("5");
    apnsReply = () => Response.json({ reason: "PayloadTooLarge" }, { status: 413 });
    expect((await call("/v1/push", await signed(host, { cap }))).status).toBe(422);

    // An expired provider token is renewed once.
    let first = true;
    apnsReply = () => {
      if (first) {
        first = false;
        return Response.json({ reason: "ExpiredProviderToken" }, { status: 403 });
      }
      return new Response(null, { status: 200 });
    };
    expect((await call("/v1/push", await signed(host, { cap }))).status).toBe(200);
  });

  it("drives Live Activities on the liveactivity topic", async () => {
    const host = await daemon();
    const { cap } = await register(host, { kind: "activity" });
    const start = await signed(host, {
      cap,
      push_type: "live_activity",
      category: undefined,
      event: "start",
      urgent: true,
      stale: 1_900_000_000,
    });
    expect((await call("/v1/push", start)).status).toBe(200);
    const sealed = JSON.parse(new TextDecoder().decode(start.body as Uint8Array)).sealed;
    const [firstCall] = apnsCalls;
    expect(firstCall.headers.get("apns-push-type")).toBe("liveactivity");
    expect(firstCall.headers.get("apns-topic")).toBe("dev.gudo.app.push-type.liveactivity");
    expect(firstCall.headers.get("apns-priority")).toBe("10");
    expect(firstCall.body.aps).toMatchObject({
      event: "start",
      "content-state": { s: sealed, v: 1 },
      "stale-date": 1_900_000_000,
      "attributes-type": "AgentsActivityAttributes",
      attributes: { v: 1 },
    });
    expect(firstCall.body.aps.alert.title).toBe("Agents");

    const end = await signed(host, {
      cap,
      push_type: "live_activity",
      category: undefined,
      event: "end",
      dismiss: 1_900_000_100,
    });
    expect((await call("/v1/push", end)).status).toBe(200);
    expect(apnsCalls[1].headers.get("apns-priority")).toBe("5");
    expect(apnsCalls[1].body.aps["dismissal-date"]).toBe(1_900_000_100);
    expect(apnsCalls[1].body.aps.attributes).toBeUndefined();
  });

  it("limits registrations per client address", async () => {
    const host = await daemon();
    let status = 200;
    for (let i = 0; i < 25 && status === 200; i++) {
      status = (
        await call("/v1/register", {
          method: "POST",
          headers: { "cf-connecting-ip": "203.0.113.9" },
          body: JSON.stringify({ token: TOKEN, env: "production", daemon: host.id }),
        })
      ).status;
    }
    expect(status).toBe(429);
  });

  it("counts a whole IPv6 /64 as one client", async () => {
    const host = await daemon();
    let status = 200;
    for (let i = 0; i < 25 && status === 200; i++) {
      status = (
        await call("/v1/register", {
          method: "POST",
          headers: { "cf-connecting-ip": `2001:db8:1:2::${(i + 1).toString(16)}` },
          body: JSON.stringify({ token: TOKEN, env: "production", daemon: host.id }),
        })
      ).status;
    }
    expect(status).toBe(429);
    expect(addressKey("2001:db8:1:2::1")).toBe(addressKey("2001:0db8:0001:0002:ffff:0:0:9"));
    expect(addressKey("2001:db8:1:3::1")).not.toBe(addressKey("2001:db8:1:2::1"));
    expect(addressKey("::1")).toBe("0:0:0:0::/64");
    expect(addressKey("203.0.113.9")).toBe("203.0.113.9");
  });

  it("does not let a request with a future timestamp be replayed later", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const start = Date.now();
    const once = await signed(host, { cap, ts: start + 4 * 60 * 1000 });
    expect((await call("/v1/push", once)).status).toBe(200);
    // Six minutes on, the request's own timestamp is still within the accepted skew.
    vi.spyOn(Date, "now").mockReturnValue(start + 6 * 60 * 1000);
    expect((await call("/v1/push", once)).status).toBe(409);
    expect(apnsCalls).toHaveLength(1);
  });

  it("limits pushes per device token across daemons", async () => {
    // Anyone who learns a device's APNs token can bind it to daemons of their own; the
    // device still gets no more than its own budget.
    let limited: Response | undefined;
    for (let i = 0; i < ALERT_TOKEN_BUCKET.capacity + 1 && !limited; i++) {
      const host = await daemon();
      const { cap } = await register(host);
      const response = await call("/v1/push", await signed(host, { cap, category: "done" }));
      if (response.status === 429) limited = response;
      else expect(response.status).toBe(200);
    }
    expect(limited, "the device's bucket ran out").toBeDefined();
    expect(await limited!.json()).toEqual({ error: "too many pushes to this device" });
    expect(apnsCalls).toHaveLength(ALERT_TOKEN_BUCKET.capacity);
  });

  it("refuses oversized bodies without reading them whole", async () => {
    const big = "x".repeat(MAX_BODY + 1);
    expect((await call("/v1/register", { method: "POST", body: big })).status).toBe(413);
    // No content-length: a streamed body is cut off at the limit.
    const chunks = (chunkCount: number) => {
      const pulled = { count: 0 };
      const body = new ReadableStream<Uint8Array>({
        pull(controller) {
          if (pulled.count++ === chunkCount) controller.close();
          else controller.enqueue(new Uint8Array(4096));
        },
      });
      return { pulled, init: { method: "POST", body, duplex: "half" } as RequestInit };
    };
    const streamed = chunks(4);
    expect((await call("/v1/push", streamed.init)).status).toBe(413);
    // A declared length over the limit is refused before reading anything.
    const declared = chunks(4);
    const init = { ...declared.init, headers: { "content-length": String(4 * 4096) } };
    expect((await call("/v1/push", init)).status).toBe(413);
    // (The runtime may read ahead one chunk; reading to the limit takes three.)
    expect(declared.pulled.count).toBeLessThan(3);
  });

  it("refuses header injection and loose types", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    for (const bad of [
      { collapse: "a\r\nx-evil: 1" },
      { collapse: "not hex" },
      { urgent: "yes" },
      { ts: Date.now() + 0.5 },
      { stale: -1 },
      { category: ["approval"] },
    ] as unknown as Partial<RelayRequest>[]) {
      expect((await call("/v1/push", await signed(host, { cap, ...bad }))).status, JSON.stringify(bad)).toBe(400);
    }
    expect(
      (await call("/v1/register", { method: "POST", body: JSON.stringify({ token: "abc", env: "production", daemon: host.id }) }))
        .status,
    ).toBe(400);
    expect(apnsCalls).toHaveLength(0);
  });

  it("sends security headers and no CORS on every answer", async () => {
    for (const response of [
      await call("/healthz"),
      await call("/v1/push", { method: "POST", body: "{" }),
      await call("/v1/push", { method: "OPTIONS", headers: { origin: "https://evil.test" } }),
    ]) {
      expect(response.headers.get("x-content-type-options")).toBe("nosniff");
      expect(response.headers.get("cache-control")).toBe("no-store");
      expect(response.headers.get("access-control-allow-origin")).toBeNull();
    }
  });
});

describe("formats shared with the daemon", () => {
  it("verifies a request signed by the Rust daemon code", async () => {
    const body = utf8.encode(vectors.relay_request.body);
    const parsed = parseRequest(body);
    expect(typeof parsed).toBe("object");
    const relayRequest = parsed as RelayRequest;
    expect(relayRequest.daemon).toBe(vectors.daemon_public);
    expect(relayRequest.category).toBe("approval");
    expect(await verifySignature(relayRequest.daemon, body, vectors.relay_request.signature)).toBe(true);
    const tampered = utf8.encode(vectors.relay_request.body.replace("approval", "done"));
    expect(await verifySignature(relayRequest.daemon, tampered, vectors.relay_request.signature)).toBe(false);
  });

  it("builds the APNs request for a Rust-sealed payload without touching it", () => {
    const relayRequest = parseRequest(utf8.encode(vectors.relay_request.body)) as RelayRequest;
    const apns = buildApnsRequest(
      env,
      { t: TOKEN, e: "production", d: relayRequest.daemon, k: "alert", x: 0 },
      relayRequest,
      1_760_000_000_000,
    );
    expect(JSON.parse(apns.body).s).toBe(vectors.payloads[0].sealed);
  });

  it("expires approvals with their action token", () => {
    const relayRequest = parseRequest(utf8.encode(vectors.relay_request.body)) as RelayRequest;
    const cap = { t: TOKEN, e: "production" as const, d: relayRequest.daemon, k: "alert" as const, x: 0 };
    const at = 1_760_000_000;
    const expiry = (category: RelayRequest["category"]) =>
      Number(buildApnsRequest(env, cap, { ...relayRequest, category }, at * 1000).headers["apns-expiration"]);
    // An approval held by APNs past its token would offer buttons that can only fail.
    expect(expiry("approval")).toBe(at + APPROVAL_TTL_S);
    expect(APPROVAL_TTL_S).toBe(15 * 60);
    for (const other of ["blocked", "done", "command"] as const) expect(expiry(other)).toBe(at + 3600);
  });

  it("opens capabilities sealed with the previous key during a rotation", async () => {
    const cap = { t: TOKEN, e: "production" as const, d: "00".repeat(32), k: "alert" as const, x: 1 };
    const old = await sealCap(env.PUSH_CAP_KEY_PREVIOUS!, cap);
    expect(await openCap(old, [env.PUSH_CAP_KEY, env.PUSH_CAP_KEY_PREVIOUS])).toEqual(cap);
    expect(await openCap(old, [env.PUSH_CAP_KEY])).toBeNull();
  });

  it("caches the provider JWT", async () => {
    const jwt = await providerJwt(env, 1_000_000);
    expect(await providerJwt(env, 1_000_000 + 30 * 60 * 1000)).toBe(jwt);
    expect(await providerJwt(env, 1_000_000 + 41 * 60 * 1000)).not.toBe(jwt);
  });
});

describe("attacks on the relay", () => {
  const TTL = 5 * 60 * 1000;

  it("lets exactly one of many concurrent copies of a request through", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    for (let round = 0; round < 10; round++) {
      const once = await signed(host, { cap, category: "done" });
      const statuses = await Promise.all(
        Array.from({ length: 16 }, () => call("/v1/push", once).then((response) => response.status)),
      );
      expect(statuses.filter((status) => status === 200), `round ${round}`).toHaveLength(1);
      expect(statuses.filter((status) => status === 409)).toHaveLength(15);
    }
    expect(apnsCalls).toHaveLength(10);
  });

  it("does not let concurrent requests overdraw a bucket", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const requests = await Promise.all(
      Array.from({ length: DAEMON_BUCKET.capacity + 10 }, () => signed(host, { cap, category: "done" })),
    );
    const statuses = await Promise.all(
      requests.map((init) => call("/v1/push", init).then((response) => response.status)),
    );
    expect(statuses.filter((status) => status === 200)).toHaveLength(DAEMON_BUCKET.capacity);
  });

  it("refuses a replay while the clock crosses the edge of the skew window", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const ts = Date.now();
    const once = await signed(host, { cap, ts });
    expect((await call("/v1/push", once)).status).toBe(200);
    // The skew check sees the last accepted millisecond; the clock moves on before the nonce
    // lookup.
    let calls = 0;
    vi.spyOn(Date, "now").mockImplementation(() => (calls++ === 0 ? ts + TTL : ts + TTL + 1));
    expect((await call("/v1/push", once)).status).toBe(409);
    expect(apnsCalls).toHaveLength(1);
  });

  it("keeps a future-dated nonce through cleanup until its request goes stale", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const start = Date.now();
    const once = await signed(host, { cap, ts: start + TTL - 1000 });
    expect((await call("/v1/push", once)).status).toBe(200);
    // Seven minutes on, the cleanup alarm runs; the request is still inside the skew window.
    vi.spyOn(Date, "now").mockReturnValue(start + 7 * 60 * 1000);
    const limiter = env.LIMITER.get(env.LIMITER.idFromName(`daemon:${host.id}`));
    expect(await runDurableObjectAlarm(limiter)).toBe(true);
    expect((await call("/v1/push", once)).status).toBe(409);
    expect(apnsCalls).toHaveLength(1);
  });

  it("accepts the window's edges and nothing beyond", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const now = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(now);
    for (const [ts, status] of [
      [now - TTL, 200],
      [now + TTL, 200],
      [now - TTL - 1, 401],
      [now + TTL + 1, 401],
    ]) {
      expect((await call("/v1/push", await signed(host, { cap, ts }))).status, String(ts - now)).toBe(
        status,
      );
    }
  });

  it("refuses any change to a signed body", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const good = await signed(host, { cap });
    const text = new TextDecoder().decode(good.body as Uint8Array);
    const parsed = JSON.parse(text);
    for (const body of [
      JSON.stringify({ ...parsed, sealed: b64url(crypto.getRandomValues(new Uint8Array(200))) }),
      JSON.stringify({ ...parsed, category: "done" }),
      JSON.stringify({ ...parsed, nonce: nonce() }),
      JSON.stringify({ ...parsed, ts: parsed.ts + 1 }),
      `${text} `,
      JSON.stringify(parsed, null, 1),
    ]) {
      expect((await call("/v1/push", { ...good, body })).status, body.slice(0, 40)).toBe(401);
    }
    expect((await call("/v1/push", { method: "POST", body: good.body })).status).toBe(401);
    expect(
      (await call("/v1/push", { ...good, headers: { "x-push-signature": "!!" } })).status,
    ).toBe(401);
    expect(apnsCalls).toHaveLength(0);
  });

  it("refuses a body longer than its content-length claims", async () => {
    const response = await call("/v1/push", {
      method: "POST",
      headers: { "content-length": "10" },
      body: "x".repeat(MAX_BODY + 1),
    });
    expect(response.status).toBe(413);
  });

  it("answers malformed JSON of every shape with 400, never 500", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    for (const body of ["null", "[]", '"x"', "1", "true", "{}", '{"v":"1"}']) {
      expect((await call("/v1/push", { method: "POST", body })).status, body).toBe(400);
      expect((await call("/v1/register", { method: "POST", body })).status, body).toBe(400);
    }
    for (const bad of [
      { daemon: 1 },
      { cap: { a: 1 } },
      { sealed: null },
      { ts: "1" },
      { ts: -1 },
      { ts: 1e300 },
      { nonce: 7 },
      { nonce: "AB".repeat(8) },
      { collapse: "AB" },
      { collapse: "ａ" },
      { collapse: "" },
      { v: 2 },
    ] as unknown as Partial<RelayRequest>[]) {
      expect((await call("/v1/push", await signed(host, { cap, ...bad }))).status, JSON.stringify(bad)).toBe(
        400,
      );
    }
    for (const bad of [
      { token: ["ab"] },
      { daemon: 1 },
      { kind: "admin" },
      { env: "Production" },
      { token: `${"ab".repeat(8)}\r\n` },
    ]) {
      const body = JSON.stringify({ token: TOKEN, env: "production", daemon: host.id, ...bad });
      expect((await call("/v1/register", { method: "POST", body })).status, JSON.stringify(bad)).toBe(400);
    }
    expect(apnsCalls).toHaveLength(0);
  });

  it("puts only the relay's own headers on the APNs request", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    expect((await call("/v1/push", await signed(host, { cap, collapse: "ab" }))).status).toBe(200);
    const [sent] = apnsCalls;
    expect([...sent.headers.keys()].sort()).toEqual([
      "apns-collapse-id",
      "apns-expiration",
      "apns-priority",
      "apns-push-type",
      "apns-topic",
      "authorization",
      "content-type",
    ]);
    expect(sent.headers.get("apns-topic")).toBe(env.APNS_TOPIC);
    expect(sent.url).toBe(`https://api.push.apple.com/3/device/${TOKEN}`);
  });

  it("counts a token's spellings and its daemons as one device", async () => {
    const token = TOKEN;
    let limited = false;
    for (let i = 0; i < ALERT_TOKEN_BUCKET.capacity + 1 && !limited; i++) {
      const host = await daemon();
      const { cap } = await register(host, { token: i % 2 ? token.toUpperCase() : token });
      limited = (await call("/v1/push", await signed(host, { cap, category: "done" }))).status === 429;
    }
    expect(limited).toBe(true);
    expect(apnsCalls).toHaveLength(ALERT_TOKEN_BUCKET.capacity);
  });

  it("does not let activity pushes refill a device's alert budget", async () => {
    const host = await daemon();
    const { cap } = await register(host);
    const { cap: activityCap } = await register(host, { kind: "activity" });
    const start = Date.now();
    vi.spyOn(Date, "now").mockReturnValue(start);
    const alert = async () =>
      (await call("/v1/push", await signed(host, { cap, category: "done" }))).status;
    for (let i = 0; i < ALERT_TOKEN_BUCKET.capacity; i++) expect(await alert()).toBe(200);
    expect(await alert()).toBe(429);
    // A minute on the alert budget has regained 5; an activity push in between changes nothing.
    vi.spyOn(Date, "now").mockReturnValue(start + 60_000);
    const update = await signed(host, {
      cap: activityCap,
      push_type: "live_activity",
      category: undefined,
      event: "update",
    });
    expect((await call("/v1/push", update)).status).toBe(200);
    let sent = 0;
    for (let i = 0; i < 10; i++) if ((await alert()) === 200) sent++;
    expect(sent).toBe(Math.floor(60 * ALERT_TOKEN_BUCKET.refill));
  });

  it("keys IPv4-mapped addresses by their IPv4 address", async () => {
    expect(addressKey("::ffff:203.0.113.9")).toBe("203.0.113.9");
    expect(addressKey("::FFFF:198.51.100.1")).toBe("198.51.100.1");
    expect(addressKey("0:0:0:0:0:ffff:203.0.113.9")).toBe("203.0.113.9");
    expect(addressKey("2001:DB8:1:2::5")).toBe(addressKey("2001:db8:1:2:a:b:c:host"));
    // Mapped clients do not all share one budget.
    const host = await daemon();
    const registerFrom = (ip: string) =>
      call("/v1/register", {
        method: "POST",
        headers: { "cf-connecting-ip": ip },
        body: JSON.stringify({ token: TOKEN, env: "production", daemon: host.id }),
      }).then((response) => response.status);
    let status = 200;
    for (let i = 0; i < 25 && status === 200; i++) status = await registerFrom("::ffff:198.51.100.77");
    expect(status).toBe(429);
    expect(await registerFrom("198.51.100.77")).toBe(429);
    expect(await registerFrom("::ffff:198.51.100.78")).toBe(200);
  });
});

/**
 * One Durable Object per daemon (`daemon:<key>`) or per client IP (`ip:<addr>`): a token
 * bucket, plus the nonces a daemon used in the last [`NONCE_TTL_MS`] so a captured request
 * cannot be replayed. State lives in the object's storage, so eviction loses nothing.
 */
import { DurableObject } from "cloudflare:workers";

/** Requests are accepted within this much clock skew; nonces are kept as long. */
export const NONCE_TTL_MS = 5 * 60 * 1000;

export interface Bucket {
  /** Burst size. */
  capacity: number;
  /** Tokens per second. */
  refill: number;
}

export const DAEMON_BUCKET: Bucket = { capacity: 30, refill: 300 / (15 * 60) };
/** Registrations per client IP (an IPv6 /64): 20 an hour. */
export const REGISTER_BUCKET: Bucket = { capacity: 20, refill: 20 / 3600 };
/**
 * Alerts per APNs token, across all daemons: bounds what anyone who binds a leaked token to
 * daemons of their own can send it (300 an hour, burst 30).
 */
export const ALERT_TOKEN_BUCKET: Bucket = { capacity: 30, refill: 300 / 3600 };
/** Live Activity pushes per activity token; every host updates the same one. */
export const ACTIVITY_TOKEN_BUCKET: Bucket = { capacity: 60, refill: 1 / 3 };

export type Verdict =
  | { ok: true }
  | { ok: false; reason: "rate"; retryAfter: number }
  | { ok: false; reason: "replay" };

interface State {
  tokens: number;
  at: number;
}

export class RateLimiter extends DurableObject {
  /**
   * Takes one token, and records `nonce` (refusing one seen before) until `nonceUntil`: the
   * last moment its request is still inside the accepted clock skew.
   */
  async take(
    bucket: Bucket,
    nonce: string | null,
    now: number,
    nonceUntil = now + NONCE_TTL_MS,
  ): Promise<Verdict> {
    const storage = this.ctx.storage;
    // Any remembered nonce is a replay: comparing its expiry with `now` would let one through
    // when the clock moves between the caller's skew check and this call.
    if (nonce !== null && (await storage.get<number>(`n:${nonce}`)) !== undefined) {
      return { ok: false, reason: "replay" };
    }
    const state = (await storage.get<State>("bucket")) ?? { tokens: bucket.capacity, at: now };
    const tokens = Math.min(bucket.capacity, state.tokens + ((now - state.at) / 1000) * bucket.refill);
    if (tokens < 1) {
      await storage.put("bucket", { tokens, at: now });
      return { ok: false, reason: "rate", retryAfter: Math.ceil((1 - tokens) / bucket.refill) };
    }
    await storage.put("bucket", { tokens: tokens - 1, at: now });
    if (nonce !== null) {
      await storage.put(`n:${nonce}`, nonceUntil);
      if ((await storage.getAlarm()) === null) await storage.setAlarm(nonceUntil);
    }
    return { ok: true };
  }

  /** Forgets expired nonces. */
  async alarm(): Promise<void> {
    const now = Date.now();
    const nonces = await this.ctx.storage.list<number>({ prefix: "n:" });
    const expired = [...nonces].filter(([, until]) => until < now).map(([k]) => k);
    for (let i = 0; i < expired.length; i += 128) {
      await this.ctx.storage.delete(expired.slice(i, i + 128));
    }
    if (nonces.size > expired.length) await this.ctx.storage.setAlarm(now + NONCE_TTL_MS);
  }
}

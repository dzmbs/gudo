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
/** Registrations per client IP: 20 an hour. */
export const REGISTER_BUCKET: Bucket = { capacity: 20, refill: 20 / 3600 };

export type Verdict =
  | { ok: true }
  | { ok: false; reason: "rate"; retryAfter: number }
  | { ok: false; reason: "replay" };

interface State {
  tokens: number;
  at: number;
}

export class RateLimiter extends DurableObject {
  /** Takes one token (and records `nonce`, refusing one seen before). */
  async take(bucket: Bucket, nonce: string | null, now: number): Promise<Verdict> {
    const storage = this.ctx.storage;
    if (nonce !== null) {
      const seen = await storage.get<number>(`n:${nonce}`);
      if (seen !== undefined && seen > now) return { ok: false, reason: "replay" };
    }
    const state = (await storage.get<State>("bucket")) ?? { tokens: bucket.capacity, at: now };
    const tokens = Math.min(bucket.capacity, state.tokens + ((now - state.at) / 1000) * bucket.refill);
    if (tokens < 1) {
      await storage.put("bucket", { tokens, at: now });
      return { ok: false, reason: "rate", retryAfter: Math.ceil((1 - tokens) / bucket.refill) };
    }
    await storage.put("bucket", { tokens: tokens - 1, at: now });
    if (nonce !== null) {
      await storage.put(`n:${nonce}`, now + NONCE_TTL_MS);
      if ((await storage.getAlarm()) === null) await storage.setAlarm(now + NONCE_TTL_MS);
    }
    return { ok: true };
  }

  /** Forgets expired nonces. */
  async alarm(): Promise<void> {
    const now = Date.now();
    const nonces = await this.ctx.storage.list<number>({ prefix: "n:" });
    const expired = [...nonces].filter(([, until]) => until <= now).map(([k]) => k);
    for (let i = 0; i < expired.length; i += 128) {
      await this.ctx.storage.delete(expired.slice(i, i + 128));
    }
    if (nonces.size > expired.length) await this.ctx.storage.setAlarm(now + NONCE_TTL_MS);
  }
}

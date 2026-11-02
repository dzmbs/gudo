/** Unpadded base64url (RFC 4648 §5), the text form of every binary field. */
export function b64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decodes unpadded (or padded) base64url; `null` if malformed. */
export function unb64url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*={0,2}$/.test(text)) return null;
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

/** Lowercase hex. */
export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Decodes hex of exactly `len` bytes (any length when omitted); `null` if malformed. */
export function unhex(text: string, len?: number): Uint8Array | null {
  if (!/^([0-9a-fA-F]{2})*$/.test(text)) return null;
  const bytes = new Uint8Array(text.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(text.slice(2 * i, 2 * i + 2), 16);
  if (len !== undefined && bytes.length !== len) return null;
  return bytes;
}

export const utf8 = new TextEncoder();

export function concat(...parts: Uint8Array[]): Uint8Array {
  const joined = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  return joined;
}

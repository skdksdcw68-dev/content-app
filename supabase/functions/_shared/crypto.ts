/**
 * Envelope encryption for platform tokens.
 *
 * The key lives in the function's environment, never in the database. That is
 * the whole point of doing this at the application layer rather than with a
 * Postgres extension: a full database dump, or a leaked service-role key, is
 * worth nothing on its own.
 *
 * Layout of a sealed value: [1 byte key version][12 byte IV][ciphertext+tag].
 * The version byte is what makes key rotation a migration rather than an
 * outage -- decrypt accepts any version we still hold, encrypt always uses the
 * newest.
 */

const CURRENT_VERSION = 1;

const keyCache = new Map<number, CryptoKey>();

async function keyFor(version: number): Promise<CryptoKey> {
  const cached = keyCache.get(version);
  if (cached) return cached;

  const raw = Deno.env.get(`TOKEN_ENC_KEY_V${version}`);
  if (!raw) throw new Error(`TOKEN_ENC_KEY_V${version} is not set`);

  const bytes = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
  if (bytes.byteLength !== 32) {
    throw new Error(`TOKEN_ENC_KEY_V${version} must decode to 32 bytes, got ${bytes.byteLength}`);
  }

  const key = await crypto.subtle.importKey("raw", bytes, { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
  keyCache.set(version, key);
  return key;
}

const enc = new TextEncoder();

/**
 * `aad` binds the ciphertext to the row it belongs to -- pass something like
 * `${connectionId}:access`. Without it, anyone able to write SQL could move one
 * user's ciphertext into another user's row and post as them; with it, the
 * moved value simply fails to decrypt.
 */
export async function seal(plaintext: string, aad: string): Promise<string> {
  const key = await keyFor(CURRENT_VERSION);
  const iv = crypto.getRandomValues(new Uint8Array(12));

  const ct = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: enc.encode(aad) },
    key,
    enc.encode(plaintext),
  );

  const out = new Uint8Array(1 + iv.byteLength + ct.byteLength);
  out[0] = CURRENT_VERSION;
  out.set(iv, 1);
  out.set(new Uint8Array(ct), 1 + iv.byteLength);

  return toHex(out);
}

export async function open(hex: string, aad: string): Promise<string> {
  const bytes = fromHex(hex);
  const version = bytes[0];
  if (version === undefined) throw new Error("sealed value is empty");

  const key = await keyFor(version);
  const iv = bytes.slice(1, 13);
  const ct = bytes.slice(13);

  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData: enc.encode(aad) },
    key,
    ct,
  );
  return new TextDecoder().decode(plain);
}

export const keyVersion = CURRENT_VERSION;

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function fromHex(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) throw new Error("hex string has odd length");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

/** A URL-safe random token, used for OAuth state. */
export function randomToken(bytes = 32): string {
  return toHex(crypto.getRandomValues(new Uint8Array(bytes)));
}

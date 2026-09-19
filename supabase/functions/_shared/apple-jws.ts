/**
 * Checking that something really came from Apple.
 *
 * StoreKit 2 transactions and App Store Server Notifications arrive as JWS
 * signed by Apple, with the certificate chain in the header (x5c). Trusting
 * the payload means proving three things, all done here with no key of ours:
 *
 *   1. The chain ends at Apple Root CA - G3, pinned by its SHA-256 (fetched
 *      from apple.com/certificateauthority, 19 Sep 2026).
 *   2. Each certificate is signed by the next one up, and the two below the
 *      root carry Apple's App Store receipt-signing OIDs.
 *   3. The JWS itself is signed by the leaf.
 *
 * A phone can send us any bytes it likes; only these checks make "the person
 * paid" a fact rather than a claim.
 */

import { X509Certificate } from "npm:@peculiar/x509@1.12.3";

const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
/** Apple's receipt-signing leaf and its intermediate. */
const LEAF_OID = "1.2.840.113635.100.6.11.1";
const INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

function b64urlToBytes(value: string): Uint8Array {
  const b64 = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function b64ToBytes(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export class AppleSignatureError extends Error {}

/** Verifies an Apple-signed JWS and returns its payload. Throws when any
 *  link in the chain does not hold. */
export async function verifyAppleJWS<T = Record<string, unknown>>(jws: string): Promise<T> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppleSignatureError("not a JWS");
  const [headerPart, payloadPart, signaturePart] = parts;

  const header = JSON.parse(new TextDecoder().decode(b64urlToBytes(headerPart))) as { alg?: string; x5c?: string[] };
  if (header.alg !== "ES256") throw new AppleSignatureError("unexpected algorithm");
  if (!Array.isArray(header.x5c) || header.x5c.length < 3) throw new AppleSignatureError("no certificate chain");

  const ders = header.x5c.map(b64ToBytes);
  const [leaf, intermediate, root] = ders.map((der) => new X509Certificate(der));

  if (await sha256Hex(ders[2]) !== APPLE_ROOT_G3_SHA256) throw new AppleSignatureError("chain does not end at Apple's root");
  if (!leaf.getExtension(LEAF_OID)) throw new AppleSignatureError("leaf is not an App Store signing certificate");
  if (!intermediate.getExtension(INTERMEDIATE_OID)) throw new AppleSignatureError("intermediate is not Apple's WWDR");

  const now = new Date();
  for (const cert of [leaf, intermediate, root]) {
    if (cert.notBefore > now || cert.notAfter < now) throw new AppleSignatureError("certificate out of date");
  }
  if (!(await intermediate.verify({ publicKey: root, signatureOnly: true }))) {
    throw new AppleSignatureError("intermediate not signed by root");
  }
  if (!(await leaf.verify({ publicKey: intermediate, signatureOnly: true }))) {
    throw new AppleSignatureError("leaf not signed by intermediate");
  }

  const key = await crypto.subtle.importKey(
    "spki",
    leaf.publicKey.rawData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    b64urlToBytes(signaturePart),
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!ok) throw new AppleSignatureError("signature does not match");

  return JSON.parse(new TextDecoder().decode(b64urlToBytes(payloadPart))) as T;
}

/** The fields of a signed transaction we act on. */
export interface AppleTransaction {
  bundleId: string;
  productId: string;
  originalTransactionId: string;
  transactionId: string;
  purchaseDate: number;
  expiresDate?: number;
  revocationDate?: number;
  offerType?: number;
  offerDiscountType?: string;
  appAccountToken?: string;
  environment?: string;
  type?: string;
}

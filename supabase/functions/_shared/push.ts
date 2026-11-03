/**
 * Push notifications through Apple (APNs), signed with a token key (.p8).
 *
 * Secrets: APNS_KEY (the whole text of the .p8 file) and APNS_KEY_ID (the
 * 10-character id Apple shows next to the key). Until both are set, nothing is
 * sent and nothing fails.
 *
 * What a person turned off lives in their user_metadata `notify_off`: a list of
 * kinds ("video", "picture", "voice", "reply", "drop", "report") or "all".
 */
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";

const TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "TDMFXRJYN7";
const KEY_ID = Deno.env.get("APNS_KEY_ID");
const KEY_PEM = Deno.env.get("APNS_KEY");
/** The app's bundle id. Still "Autocast" after the rename. */
const TOPIC = "Autocast";

export type PushKind = "video" | "picture" | "voice" | "reply" | "drop" | "report";

export type Note = {
  title: string;
  body: string;
  /** The conversation a tap opens. */
  thread?: string | null;
};

let signed: { jwt: string; at: number } | null = null;

function base64url(bytes: Uint8Array): string {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Apple accepts one token for up to an hour; a new one every 50 minutes. */
async function providerToken(): Promise<string | null> {
  if (!KEY_ID || !KEY_PEM) return null;
  const now = Math.floor(Date.now() / 1000);
  if (signed && now - signed.at < 50 * 60) return signed.jwt;
  const body = KEY_PEM.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encode = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: "ES256", kid: KEY_ID })}.${encode({ iss: TEAM_ID, iat: now })}`;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
  signed = { jwt: `${unsigned}.${base64url(new Uint8Array(signature))}`, at: now };
  return signed.jwt;
}

/** Whether this person still wants this kind of ping. */
export async function wantsPush(admin: SupabaseClient, userId: string, kind: PushKind): Promise<boolean> {
  const { data } = await admin.auth.admin.getUserById(userId);
  const off = data?.user?.user_metadata?.notify_off;
  if (!Array.isArray(off)) return true;
  return !off.includes("all") && !off.includes(kind);
}

/** Sends to every phone this person is signed in on. Returns how many took it. */
export async function push(admin: SupabaseClient, userId: string, kind: PushKind, note: Note): Promise<number> {
  const jwt = await providerToken();
  if (!jwt) {
    console.log("push: no APNs key yet");
    return 0;
  }
  if (!(await wantsPush(admin, userId, kind))) return 0;
  const { data: devices } = await admin.from("push_devices").select("token, environment").eq("user_id", userId);
  let sent = 0;
  for (const device of devices ?? []) {
    const host = device.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    try {
      const response = await fetch(`https://${host}/3/device/${device.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          aps: {
            alert: { title: note.title.slice(0, 120), body: note.body.slice(0, 240) },
            sound: "default",
            "thread-id": note.thread ?? kind,
          },
          thread: note.thread ?? null,
          kind,
        }),
        signal: AbortSignal.timeout(10_000),
      });
      if (response.ok) {
        sent++;
        continue;
      }
      const reason = String((await response.json().catch(() => ({})))?.reason ?? "");
      // Apple says this phone is gone or never belonged to this app.
      if (response.status === 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)) {
        await admin.from("push_devices").delete().eq("token", device.token);
      }
      console.log("push: apns refused", response.status, reason);
    } catch (error) {
      console.log("push: apns unreachable", String(error));
    }
  }
  return sent;
}

/** A health check: Apple's answer to a fake phone. "BadDeviceToken" means the
 *  key, team and app are all accepted. */
export async function probeApns(): Promise<{ status: number; reason: string }> {
  const jwt = await providerToken();
  if (!jwt) return { status: 0, reason: "no key" };
  const response = await fetch(`https://api.push.apple.com/3/device/${"0".repeat(64)}`, {
    method: "POST",
    headers: { authorization: `bearer ${jwt}`, "apns-topic": TOPIC, "apns-push-type": "alert", "content-type": "application/json" },
    body: JSON.stringify({ aps: { alert: "probe" } }),
    signal: AbortSignal.timeout(10_000),
  });
  return { status: response.status, reason: String((await response.json().catch(() => ({})))?.reason ?? "") };
}

/** True the first time a key is claimed: one ping per job or per set. */
export async function firstTime(admin: SupabaseClient, key: string): Promise<boolean> {
  const { data } = await admin.from("push_sent").upsert({ key }, { onConflict: "key", ignoreDuplicates: true }).select("key");
  return (data ?? []).length > 0;
}

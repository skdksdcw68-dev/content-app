/**
 * Turns something somebody said into words: a voice note recorded in the chat,
 * or the soundtrack the phone pulled out of a video they sent.
 *
 * Abel, 2 Nov 2026: "make sure it can also send voices ... when I send it a
 * video, it extracts and transcribes it and helps me."
 *
 * The phone does the extracting (a video's audio is a few megabytes; the video
 * itself is a few hundred), uploads the sound to the person's own folder, and
 * asks for the words here. Nothing is stored beyond that upload: the transcript
 * goes back to the phone and becomes part of the message.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight, PublicError } from "../_shared/http.ts";
import { recordUsage } from "../_shared/usage.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_KEY = Deno.env.get("OPENAI_API_KEY");

/** OpenAI's own limit for one file. */
const MAX_BYTES = 24 * 1024 * 1024;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);
    if (!OPENAI_KEY) throw new PublicError("Transcribing isn't set up here yet.", 503);

    // The gateway has already checked this sign-in (verify_jwt in config.toml),
    // so the person is read from the token instead of asked of the auth server
    // again -- that second trip was about half the wait for a voice note.
    const userId = signedInUser(authorization) ?? (await createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    }).auth.getUser()).data.user?.id;
    if (!userId) throw new PublicError("Sign in first.", 401);
    const auth = { user: { id: userId } };

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    let file: Blob;
    let name = "audio.m4a";
    const type = request.headers.get("Content-Type") ?? "";
    if (type.startsWith("audio/")) {
      // A voice note comes in the request itself: no upload first and no
      // download here, so the words are back in about a second (Abel, 4 Nov
      // 2026: "they are so fast" -- ChatGPT and Claude beside ours).
      file = new Blob([await request.arrayBuffer()], { type });
      // OpenAI reads the format from the name, so it must say what this is.
      const ext = type.includes("mpeg") || type.includes("mp3")
        ? "mp3"
        : type.includes("wav")
        ? "wav"
        : type.includes("webm")
        ? "webm"
        : "m4a";
      name = `note.${ext}`;
    } else {
      const body = (await request.json().catch(() => ({}))) as { path?: string };
      const path = String(body.path ?? "");
      // Their own folder and nobody else's.
      if (!path.startsWith(`${auth.user.id}/uploads/`) || path.includes("..")) {
        throw new PublicError("That file isn't yours.", 403);
      }
      const { data, error } = await admin.storage.from("artifacts").download(path);
      if (error || !data) throw new PublicError("That recording didn't arrive. Try again.", 404);
      file = data;
      name = path.split("/").pop() ?? name;
    }
    if (file.size === 0) throw new PublicError("That recording came through empty. Try again.", 400);
    if (file.size > MAX_BYTES) {
      throw new PublicError("That's too long to listen to in one go. Try a shorter one, under about 20 minutes.", 413);
    }

    const form = new FormData();
    form.append("model", "gpt-4o-mini-transcribe");
    form.append("response_format", "json");
    form.append("file", file, name);

    const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${OPENAI_KEY}` },
      body: form,
    });
    if (!response.ok) {
      console.error("transcribe", response.status, (await response.text()).slice(0, 300));
      throw new PublicError("I couldn't make out that recording. Try once more.", 502);
    }
    const result = await response.json();
    const text = typeof result?.text === "string" ? result.text.trim() : "";

    // Logged like every other model call, with the tokens the API reports.
    await recordUsage(admin, {
      userId: auth.user.id,
      kind: "transcribe",
      model: "gpt-4o-mini-transcribe",
      usage: result?.usage
        ? { prompt_tokens: result.usage.input_tokens, completion_tokens: result.usage.output_tokens }
        : null,
    }).catch(() => {});

    return json({ text });
  } catch (thrown) {
    return fail(thrown);
  }
});

/** The signed-in person's id from a token the gateway already verified; null
 *  for anything else (the anon key carries no person). */
function signedInUser(authorization: string): string | null {
  try {
    const token = authorization.replace(/^Bearer\s+/i, "");
    const part = token.split(".")[1];
    if (!part) return null;
    const payload = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=")));
    return payload?.role === "authenticated" && typeof payload.sub === "string" ? payload.sub : null;
  } catch {
    return null;
  }
}

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

    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authorization } } });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const body = (await request.json().catch(() => ({}))) as { path?: string };
    const path = String(body.path ?? "");
    // Their own folder and nobody else's.
    if (!path.startsWith(`${auth.user.id}/uploads/`) || path.includes("..")) {
      throw new PublicError("That file isn't yours.", 403);
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: file, error } = await admin.storage.from("artifacts").download(path);
    if (error || !file) throw new PublicError("That recording didn't arrive. Try again.", 404);
    if (file.size > MAX_BYTES) {
      throw new PublicError("That's too long to listen to in one go. Try a shorter one, under about 20 minutes.", 413);
    }

    const form = new FormData();
    form.append("model", "gpt-4o-mini-transcribe");
    form.append("response_format", "json");
    form.append("file", file, path.split("/").pop() ?? "audio.m4a");

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

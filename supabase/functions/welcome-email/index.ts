/**
 * Sends the welcome email, once per person. Called by the database
 * (trigger `auth_users_welcome`, 0104) when an address is confirmed on an
 * account; not by the app. The shared cron secret is the key.
 *
 * Mail goes through Resend from mail.netrocast.com (verified 8 Nov 2026).
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CRON_SECRET");
const RESEND_KEY = Deno.env.get("RESEND_API_KEY");

const sameText = (a: string, b: string) => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
};

const page = `<!doctype html><html><body style="margin:0;background:#f6f5fb;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;color:#16141f">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="480" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:20px;padding:32px">
<tr><td>
<div style="font-size:22px;font-weight:700;color:#5c4de6">Postpilot</div>
<h1 style="font-size:24px;margin:20px 0 8px">Welcome. Let’s make your first video.</h1>
<p style="font-size:16px;line-height:1.5;color:#4a4760;margin:0 0 16px">Open the app, type an idea, and Postpilot writes the script, records the voice, adds the pictures and captions, and gets it ready to post.</p>
<p style="font-size:16px;line-height:1.5;color:#4a4760;margin:0 0 16px">Try one of the templates on Home, or just ask in Chat for a scary story, a motivation reel or a “did you know”.</p>
<p style="font-size:14px;line-height:1.5;color:#8a869e;margin:24px 0 0">You got this email because you created a Postpilot account. Reply to it if you need help.</p>
</td></tr></table></td></tr></table></body></html>`;

Deno.serve(async (request) => {
  if (!CRON_SECRET || !sameText(request.headers.get("x-cron-secret") ?? "", CRON_SECRET)) {
    return json({ error: "no" }, 401);
  }
  if (!RESEND_KEY) return json({ error: "no mail key" }, 500);
  const { user_id: userId } = await request.json().catch(() => ({}));
  if (typeof userId !== "string") return json({ error: "user_id" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data } = await admin.auth.admin.getUserById(userId);
  const email = data?.user?.email;
  if (!email || data?.user?.is_anonymous) return json({ sent: 0 });

  // Claim it first, so two calls at once send one email.
  const { error: claimed } = await admin.from("welcome_sent").insert({ user_id: userId });
  if (claimed) return json({ sent: 0, already: true });

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: "Postpilot <hello@mail.netrocast.com>",
      to: [email],
      subject: "Welcome to Postpilot",
      html: page,
    }),
  });
  if (!response.ok) {
    // Let a later confirmation try again.
    await admin.from("welcome_sent").delete().eq("user_id", userId);
    console.log("welcome: resend refused", response.status);
    return json({ sent: 0 }, 502);
  }
  return json({ sent: 1 });
});

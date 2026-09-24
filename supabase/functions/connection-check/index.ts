/**
 * Every endpoint of one connection, hit for real, and an honest report.
 *
 * Abel, 24 Sep 2026: "I tested connecting via Higgsfield MCP, and right after
 * the MCP it cannot read through the API... I want it to actually hit every
 * single endpoint from every single possible endpoint. And if that's not
 * possible, the AI should literally tell a corrected and verified answer that
 * it cannot hit the endpoint where it's supposed to hit, and when it can hit,
 * and when it can't -- and it should try to find another way."
 *
 * So this is not a health flag. It calls each step against the live server and
 * reports what answered, what refused, and what it said. Nothing is inferred
 * from a stored column; every line here is a round trip made just now.
 *
 * It is deliberately READ-ONLY. Nothing here generates anything, so it can be
 * run as often as somebody likes and can never cost a credit.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { fail, json, preflight, PublicError } from "../_shared/http.ts";
import { openConnection } from "../_shared/connectors/tokens.ts";
import { McpSession, providerFamily } from "../_shared/connectors/mcp.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

/** One thing that was tried. `ok` is whether the server answered it. */
interface Step {
  step: string;
  ok: boolean;
  /** What came back, or why it did not. Always populated -- an empty detail
   *  is how a check becomes a shrug. */
  detail: string;
  /** Milliseconds the round trip took, so a slow server is visible as slow
   *  rather than as broken. */
  ms: number;
}

const CAPABILITY_KIND: Record<string, string> = {
  video_generation: "video",
  image_generation: "image",
  audio_generation: "audio",
  voice_generation: "audio",
};

async function timed<T>(run: () => Promise<T>): Promise<[T | null, string, number]> {
  const started = Date.now();
  try {
    const value = await run();
    return [value, "", Date.now() - started];
  } catch (thrown) {
    const message = thrown instanceof Error ? thrown.message : String(thrown);
    return [null, message.slice(0, 300), Date.now() - started];
  }
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return preflight();
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) throw new PublicError("Sign in first.", 401);

    const asUser = createClient(SUPABASE_URL, ANON_KEY, {
      global: { headers: { Authorization: authorization } },
    });
    const { data: auth } = await asUser.auth.getUser();
    if (!auth.user) throw new PublicError("Sign in first.", 401);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const body = (await request.json().catch(() => ({}))) as { connection_id?: string };

    // The connection asked for, or this person's newest live one.
    let connectionId = body.connection_id;
    if (!connectionId) {
      const { data } = await admin
        .from("connections")
        .select("id")
        .eq("user_id", auth.user.id)
        .eq("status", "active")
        .order("created_at", { ascending: false })
        .limit(1);
      connectionId = (data ?? [])[0]?.id;
    } else {
      // Asking about somebody else's connection is not a thing.
      const { data } = await admin
        .from("connections")
        .select("id")
        .eq("id", connectionId)
        .eq("user_id", auth.user.id)
        .limit(1);
      if (!(data ?? []).length) throw new PublicError("That connection is not yours.", 404);
    }
    if (!connectionId) throw new PublicError("No connected provider to check.", 404);

    const steps: Step[] = [];
    const opened = await openConnection(admin, connectionId);

    if (opened.authKind === "api_key") {
      return json({
        connection_id: connectionId,
        provider: opened.providerSlug,
        transport: "api_key",
        steps: [{
          step: "Credential",
          ok: Boolean(opened.secret),
          detail: opened.secret ? "A key is stored for this provider." : "No key is stored.",
          ms: 0,
        }],
        models: {},
        summary: "Pasted keys are used directly by each job; there is no session to open.",
      });
    }

    const family = providerFamily(opened.providerSlug, opened.endpoint);
    const session = new McpSession(opened.endpoint, opened.secret);

    // 1. The session. Everything else depends on it, so a failure here stops.
    const [info, openError, openMs] = await timed(() => session.open());
    steps.push({
      step: "Open a session (initialize)",
      ok: Boolean(info),
      detail: info
        ? `Answered as "${(info.serverInfo as { name?: string })?.name ?? "unnamed server"}".`
        : `Refused: ${openError}`,
      ms: openMs,
    });

    if (!info) {
      return json({
        connection_id: connectionId,
        provider: opened.providerSlug,
        endpoint: opened.endpoint,
        family,
        steps,
        models: {},
        summary: "The server would not open a session, so nothing else could be tried. Sign in to it again.",
      });
    }

    // 2. What it can do at all.
    const [tools, toolsError, toolsMs] = await timed(() => session.tools());
    const toolNames = (tools ?? []).map((t) => t.name);
    steps.push({
      step: "List the tools (tools/list)",
      ok: Boolean(tools),
      detail: tools
        ? `${toolNames.length} tools: ${toolNames.slice(0, 12).join(", ")}${toolNames.length > 12 ? "…" : ""}`
        : `Refused: ${toolsError}`,
      ms: toolsMs,
    });

    steps.push({
      step: "Recognise the server",
      ok: family !== opened.providerSlug || Boolean(toolNames.length),
      detail: family !== opened.providerSlug
        ? `Read as "${family}" from its address, so its own tool and model tables are used.`
        : `No built-in table for "${opened.providerSlug}"; capabilities are read from the tool names.`,
      ms: 0,
    });

    // 3. Every model list it will give us, one call per kind. This is the step
    //    that was quietly returning nothing and taking the whole product down
    //    with it, so it is reported per kind with the count it actually gave.
    const models: Record<string, number> = {};
    const catalogueTool = toolNames.find((n) => n === "models_explore" || /models?_(list|explore|search)/.test(n));

    if (catalogueTool) {
      for (const kind of ["video", "image", "audio"]) {
        const [result, error, ms] = await timed(() =>
          session.call("tools/call", {
            name: catalogueTool,
            arguments: { action: "list", limit: 100, type: kind },
          })
        );
        let count = 0;
        if (result) {
          const content = (result as { content?: Array<{ type: string; text?: string }> }).content;
          const texts = Array.isArray(content) ? content : [];
          for (const part of texts) {
            if (part.type === "text" && part.text) {
              try {
                const parsed = JSON.parse(part.text);
                const items = parsed.items ?? parsed.models ?? parsed.data;
                if (Array.isArray(items)) count = items.length;
              } catch { /* not JSON; count stays 0 */ }
            }
          }
        }
        models[kind] = count;
        steps.push({
          step: `Ask for ${kind} models (${catalogueTool})`,
          ok: Boolean(result) && count > 0,
          detail: result
            ? (count > 0 ? `${count} models.` : "Answered, but listed no models. This is what makes generation fail with no_models.")
            : `Refused: ${error}`,
          ms,
        });
      }
    } else {
      steps.push({
        step: "Ask for models",
        ok: false,
        detail: "This server has no model-listing tool, so each capability gets one generic entry. That is honest, not a failure.",
        ms: 0,
      });
    }

    // 4. Credits, where the server will say. A read, never a purchase.
    const balanceTool = toolNames.find((n) => n === "balance" || /credits?$|balance/.test(n));
    if (balanceTool) {
      const [result, error, ms] = await timed(() =>
        session.call("tools/call", { name: balanceTool, arguments: {} })
      );
      steps.push({
        step: `Read the balance (${balanceTool})`,
        ok: Boolean(result),
        detail: result ? JSON.stringify(result).slice(0, 200) : `Refused: ${error}`,
        ms,
      });
    }

    const reachable = steps.filter((s) => s.ok).length;
    const videoOk = (models.video ?? 0) > 0;
    const summary = videoOk
      ? `${reachable} of ${steps.length} checks passed. This connection can make video.`
      : `${reachable} of ${steps.length} checks passed, but no video model came back, so nothing can be generated yet.`;

    return json({
      connection_id: connectionId,
      provider: opened.providerSlug,
      endpoint: opened.endpoint,
      family,
      tools: toolNames,
      models,
      steps,
      summary,
    });
  } catch (thrown) {
    return fail(thrown);
  }
});

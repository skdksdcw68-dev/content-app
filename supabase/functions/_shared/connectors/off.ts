/**
 * Nobody connects their own models, API keys or MCP servers (Abel, 8 Nov 2026:
 * "nobody can use it via connector and MCP, or from an API key. It only works
 * on my own models").
 *
 * The four front doors (connect-generator, connector-start, connector-callback,
 * connector-refresh) answer 403 while this is true. The database side is
 * migration 0103: `capabilities_for` and `uses_house_generator` only look at
 * the house connection. Set to false (and revert 0103) to bring it back.
 */
export const OWN_MODELS_OFF = true;
export const OWN_MODELS_OFF_MESSAGE =
  "Connecting your own models is switched off. Postpilot makes everything with its own models.";

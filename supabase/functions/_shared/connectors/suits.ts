/**
 * Can this model do this request at all?
 *
 * Asked before a model is offered or tried, from what discovery recorded about
 * it. Higgsfield alone lists thirty-four image models, and a good share are
 * editors, upscalers and background removers that need a picture to start
 * from -- or ad tools that refuse to run without a style picked first.
 * Offering one for "make an image of a cup of tea" is offering something that
 * fails after the person chose it.
 *
 * Everything here reads the provider's own catalogue entry:
 *
 *   `parameters[].required`  a setting it will not run without, that this
 *                            request does not supply (Higgsfield's DTC Ads
 *                            needs a `style_id` picked in a separate step)
 *   `medias[].required`      an input picture it cannot run without
 *   `medias[].roles`         whether it takes a starting picture at all, or
 *                            only a video or audio to transform
 *   description and tags     "expands an image beyond its borders" is an
 *                            editor, whatever else it is called
 *
 * Two things learned the hard way are NOT used. The catalogue's "text-only"
 * filter means "takes no picture at all", which would hide GPT Image and
 * Seedance -- both fine from words. And its "recommend" is a keyword match that
 * put an outpainting tool second for a cup of tea.
 *
 * Where the catalogue says nothing, the model is allowed. A gap in what we know
 * is not a reason to hide something that may well work.
 */

type Media = { roles?: unknown; required?: unknown };
type Parameter = {
  name?: unknown;
  required?: unknown;
  default?: unknown;
  options?: unknown;
  enum?: unknown;
  values?: unknown;
};

/** What a request from this app supplies, so a model needing any of these is
 *  not ruled out for needing it. */
const SUPPLIED = new Set(["prompt", "model", "aspect_ratio", "duration", "medias", "count", "resolution", "quality", "folder_id"]);

/** Roles that mean "a thing to transform", not "a picture to start from". */
const TRANSFORM_ONLY = /^(video_references?|input_video|input_audio|audio_references?|mask)$/i;

/** Words that mark an editor rather than a maker. Read from the provider's own
 *  description and tags, the way `inferCapability` reads tool names. */
const EDITOR = /(upscal|background.?remov|remove.?background|outpaint|expands? an image|deflicker|lip.?sync|object.?replac|motion.?control|video.?edit|image.?edit|video.?to.?video|restor|denois|topaz|sprite)/i;
const MAKER = /(text.?to.?(image|video)|generation|generate)/i;

function list<T>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : [];
}

function rolesOf(metadata: Record<string, unknown>): string[] {
  return list<Media>(metadata.medias).flatMap((m) => list<string>(m.roles).map(String));
}

/** Whether a model can take a picture as its starting point or reference. */
export function takesPicture(metadata: Record<string, unknown>): boolean {
  return rolesOf(metadata).some((role) => /^(image|start_image|image_references?|reference)$/i.test(role));
}

/**
 * A setting the model will not run without, that nothing here provides.
 *
 * A required setting whose options the catalogue LISTS is not missing -- it is
 * a question, and the card asks it. That is the difference between Inworld's
 * text to speech, which names its thirteen voices, and one that wants a voice
 * id it never mentions: the first is offered with a Voice row, the second
 * would fail after somebody chose it.
 */
function needsSomethingWeLack(metadata: Record<string, unknown>): boolean {
  return list<Parameter>(metadata.parameters).some((p) =>
    (p.required === "required" || p.required === true) &&
    p.default === undefined &&
    !SUPPLIED.has(String(p.name ?? "")) &&
    optionsOf(p).length === 0
  );
}

/** The values a parameter says it accepts, however the catalogue spells it. */
export function optionsOf(parameter: Parameter): string[] {
  const raw = parameter.options ?? parameter.enum ?? parameter.values;
  if (!Array.isArray(raw)) return [];
  return raw
    .map((value) =>
      typeof value === "string"
        ? value
        : typeof value === "number"
        ? String(value)
        : typeof (value as { value?: unknown })?.value === "string"
        ? String((value as { value: string }).value)
        : ""
    )
    .filter((value) => value.length > 0);
}

function isEditor(metadata: Record<string, unknown>): boolean {
  const tags = list<string>(metadata.tags).map(String).join(" ");
  const words = `${metadata.id ?? ""} ${metadata.name ?? ""} ${metadata.description ?? ""} ${tags}`;
  // A model that says it generates from text is a maker even if it also edits.
  if (MAKER.test(tags)) return false;
  return EDITOR.test(words);
}

/** Whether a video model can START from a picture -- a first frame, not just
 *  a style reference. Animating an image needs this; "Kling 3.0 Omni Edit"
 *  takes image references but edits an existing video, and was offered for
 *  "animate this". */
function startsFromPicture(metadata: Record<string, unknown>): boolean {
  return rolesOf(metadata).some((role) => /^(image|start_image|first_frame|start_frame)$/i.test(role));
}

export function suits(metadata: Record<string, unknown>, withPicture: boolean, capability?: string): boolean {
  if (needsSomethingWeLack(metadata)) return false;

  if (withPicture) {
    return capability === "video_generation" ? startsFromPicture(metadata) : takesPicture(metadata);
  }

  // From words alone.
  if (metadata.text_only === true) return true;
  if (list<Media>(metadata.medias).some((m) => m.required === true)) return false;
  const roles = rolesOf(metadata);
  if (roles.length > 0 && roles.every((role) => TRANSFORM_ONLY.test(role))) return false;
  if (isEditor(metadata)) return false;
  return true;
}

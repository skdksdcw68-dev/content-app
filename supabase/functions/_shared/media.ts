/**
 * Checking that what came back is actually a video.
 *
 * The pipeline used to trust two things it had no business trusting. It took
 * the first `url` it found anywhere in the provider's response -- which on a
 * model that returns a poster frame alongside the clip is the thumbnail -- and
 * then it accepted whatever bytes that URL served as long as they were under
 * 45MB. A JPEG satisfies both. It would have been stored as `generated.mp4`,
 * hashed, written into `asset_variants` as `tiktok_video`, bound to a consent
 * record, and handed to the publisher, which reads variants and asks no
 * questions. Nothing between the provider and TikTok would have objected.
 *
 * So this file does the objecting. Nothing here needs a decoder: a container
 * announces what it is in its first bytes, and MP4 carries its own duration and
 * dimensions in a header box that can be walked with a DataView.
 */

/** TikTok's own limits for a video post, and the reason each one is here. */
export const LIMITS = {
  /** Under three seconds is rejected on upload. */
  minSeconds: 3,
  /** Ten minutes. Nothing this app makes is near it; a wildly long file means
   *  something else came back. */
  maxSeconds: 600,
  /** Their floor is 360px on the short side. */
  minShortSide: 360,
  /** A 1080x1920 clip of five seconds is megabytes. A file this small is a
   *  poster frame or an error page, whatever its extension says. */
  minBytes: 200 * 1024,
} as const;

export interface Inspection {
  ok: boolean;
  /** What the bytes actually are, as opposed to what they were labelled. */
  container: "mp4" | "webm" | "unknown";
  seconds: number | null;
  width: number | null;
  height: number | null;
  /** Why it was refused, said the way a person would need to hear it. */
  reason: string | null;
}

/**
 * Picks the finished video out of a provider response.
 *
 * Higgsfield's completed shape varies by model -- `video.url`, `results.raw.url`,
 * `output[].url` -- so the shape cannot be pinned. What *can* be pinned is what
 * a video URL looks like, and that a key called `thumbnail` never holds one.
 * Candidates are gathered with the path that led to them, then ranked: an
 * obvious video extension wins, an obviously-image key loses, and depth breaks
 * ties so a nested `results.raw.url` beats a sibling added later.
 */
export function pickVideoUrl(body: unknown): string | null {
  const found: Array<{ url: string; key: string; depth: number }> = [];
  const seen = new Set<unknown>();

  const walk = (node: unknown, key: string, depth: number): void => {
    if (depth > 8 || node === null || typeof node !== "object") return;
    if (seen.has(node)) return;
    seen.add(node);

    if (Array.isArray(node)) {
      for (const item of node) walk(item, key, depth + 1);
      return;
    }

    for (const [childKey, value] of Object.entries(node as Record<string, unknown>)) {
      if (typeof value === "string" && /^https?:\/\//.test(value)) {
        found.push({ url: value, key: childKey.toLowerCase(), depth });
      } else {
        walk(value, childKey.toLowerCase(), depth + 1);
      }
    }
  };

  walk(body, "", 0);
  if (found.length === 0) return null;

  const score = (candidate: { url: string; key: string; depth: number }): number => {
    const path = candidate.url.split("?")[0].toLowerCase();
    let points = 0;
    if (/\.(mp4|mov|webm|m4v)$/.test(path)) points += 100;
    if (/(^|_)video(_|$)|\bvideo\b/.test(candidate.key)) points += 40;
    if (/\.(jpe?g|png|webp|gif|avif)$/.test(path)) points -= 100;
    if (/thumb|poster|preview|cover|image|frame|snapshot/.test(candidate.key)) points -= 80;
    // A deeper hit is usually the real payload rather than a sibling summary.
    points += candidate.depth;
    return points;
  };

  const best = found.map((c) => ({ c, points: score(c) }))
    .sort((a, b) => b.points - a.points)[0];

  // Everything on offer looked like a picture. Better to report nothing found
  // than to hand back the thumbnail and call it the video.
  return best.points <= 0 ? null : best.c.url;
}

/** Reads a big-endian unsigned 32-bit value, or null past the end. */
function u32(view: DataView, offset: number): number | null {
  return offset + 4 <= view.byteLength ? view.getUint32(offset) : null;
}

/**
 * Walks MP4 boxes looking for `moov`, and inside it `mvhd` and the first
 * `tkhd` with a non-zero size.
 *
 * Boxes are [size:u32][type:4 bytes][payload], nested the same way all the way
 * down, which is what makes this ~40 lines rather than a library. `size` of 1
 * means a 64-bit size follows the type; `size` of 0 means "to end of file".
 */
function readMp4(bytes: Uint8Array): { seconds: number | null; width: number | null; height: number | null } {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let seconds: number | null = null;
  let width: number | null = null;
  let height: number | null = null;

  const scan = (start: number, end: number, depth: number): void => {
    let offset = start;
    while (offset + 8 <= end && depth < 5) {
      const size = u32(view, offset);
      if (size === null) return;
      const type = String.fromCharCode(
        bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7],
      );

      let header = 8;
      let boxSize = size;
      if (size === 1) {
        // 64-bit size. The high word is zero for anything this app will ever
        // see, so only the low word is read.
        const low = u32(view, offset + 12);
        if (low === null) return;
        boxSize = low;
        header = 16;
      } else if (size === 0) {
        boxSize = end - offset;
      }
      if (boxSize < header) return;

      const bodyAt = offset + header;

      if (type === "moov" || type === "trak" || type === "mdia") {
        scan(bodyAt, Math.min(offset + boxSize, end), depth + 1);
      } else if (type === "mvhd" && seconds === null) {
        const version = bytes[bodyAt];
        const at = version === 1 ? bodyAt + 20 : bodyAt + 12;
        const timescale = u32(view, at);
        // A 64-bit duration's low word is plenty: a video long enough to
        // overflow it is not one of ours.
        const duration = u32(view, version === 1 ? at + 8 : at + 4);
        if (timescale && duration) seconds = duration / timescale;
      } else if (type === "tkhd" && width === null) {
        const version = bytes[bodyAt];
        // Fixed 16.16 at the very end of the box. Counting from the start of
        // the payload: 4 version+flags, then creation/modification/duration --
        // 8/8/8 in version 1 against 4/4/4 in version 0, with a 4-byte track id
        // and 4 reserved between them -- which puts the end of `duration` at 36
        // or 24. Then 8 reserved, 2 layer, 2 alternate group, 2 volume,
        // 2 reserved and a 36-byte matrix: 52 more before width.
        const at = bodyAt + (version === 1 ? 36 : 24) + 52;
        const w = u32(view, at);
        const h = u32(view, at + 4);
        if (w && h) {
          width = Math.round(w / 65536);
          height = Math.round(h / 65536);
        }
      }

      offset += boxSize;
    }
  };

  scan(0, bytes.byteLength, 0);
  return { seconds, width, height };
}

/**
 * Says whether these bytes are a video this app is willing to publish.
 *
 * Deliberately refuses rather than warns. A file that reaches this point has
 * already been paid for, so the temptation is to keep it and let the platform
 * decide -- but the platform decides asynchronously, after the publish slot has
 * been spent, and a rejection that arrives an hour later reads to the user as
 * the app silently not posting.
 */
export function inspect(bytes: Uint8Array, declaredMime: string): Inspection {
  const fail = (reason: string, extra: Partial<Inspection> = {}): Inspection => ({
    ok: false,
    container: "unknown",
    seconds: null,
    width: null,
    height: null,
    reason,
    ...extra,
  });

  if (bytes.byteLength < LIMITS.minBytes) {
    return fail(
      `The generator returned only ${Math.round(bytes.byteLength / 1024)}KB, which is too small to be the video.`,
    );
  }

  // What it actually is, from its own first bytes. `ftyp` at offset 4 is the
  // MP4/MOV family; 0x1A45DFA3 is EBML, which is WebM and Matroska.
  const isMp4 = bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70;
  const isWebm = bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3;

  if (!isMp4 && !isWebm) {
    const looksLikeImage = (bytes[0] === 0xff && bytes[1] === 0xd8) ||
      (bytes[0] === 0x89 && bytes[1] === 0x50);
    return fail(
      looksLikeImage
        ? "The generator returned a picture rather than a video."
        : `The generator returned something that is not a video (declared ${declaredMime || "nothing"}).`,
    );
  }

  if (isWebm) {
    // Nothing further is read: the duration lives behind a variable-length
    // integer tree, and TikTok accepts WebM, so the container check is the
    // guard. If a provider ever ships WebM by default this is where the rest
    // of the parsing goes.
    return { ok: true, container: "webm", seconds: null, width: null, height: null, reason: null };
  }

  const { seconds, width, height } = readMp4(bytes);

  if (seconds !== null && seconds < LIMITS.minSeconds) {
    return fail(
      `The video came back ${seconds.toFixed(1)}s long, and TikTok will not take anything under ${LIMITS.minSeconds}s.`,
      { container: "mp4", seconds, width, height },
    );
  }
  if (seconds !== null && seconds > LIMITS.maxSeconds) {
    return fail(
      `The video came back ${Math.round(seconds)}s long, which is past the ${LIMITS.maxSeconds}s limit.`,
      { container: "mp4", seconds, width, height },
    );
  }
  if (width !== null && height !== null && Math.min(width, height) < LIMITS.minShortSide) {
    return fail(
      `The video came back ${width}x${height}, below the ${LIMITS.minShortSide}px minimum.`,
      { container: "mp4", seconds, width, height },
    );
  }

  // Dimensions that could not be read are not treated as a failure. The header
  // is optional in ways this parser does not chase, and refusing a paid-for
  // video because one box was laid out unusually is worse than letting the
  // platform have the last word on that one field.
  return { ok: true, container: "mp4", seconds, width, height, reason: null };
}

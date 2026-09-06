/**
 * What a person actually agreed to publish.
 *
 * Approval is not a boolean. "I approved this post" has to mean "I approved
 * this caption, these exact bytes, at this visibility" -- otherwise a caption
 * edited after approval, or a re-render that changed the video, goes out under
 * a permission nobody gave for it.
 *
 * So consent stores a hash, and the publisher recomputes it immediately before
 * posting. A mismatch stops the post and sends it back for re-approval rather
 * than publishing something the person has not seen.
 */

/**
 * Field separator: a byte that cannot occur in any of the values being joined.
 *
 * Written as a char code rather than an escape so the source stays plain ASCII
 * and greppable -- a literal NUL in a source file makes tools treat it as
 * binary, which is its own small nightmare.
 */
const SEPARATOR = String.fromCharCode(0);

export interface DigestInput {
  platform: string;
  providerUserId: string;
  caption: string;
  hashtags: string[];
  /**
   * Checksums of the **variants** -- the files that will actually be uploaded --
   * not the asset ids. Re-encoding the same source into a different JPEG
   * changes the bytes that get published, so it has to invalidate consent.
   */
  variantChecksums: string[];
  privacy: string;
  disableComment: boolean;
  disableDuet: boolean;
  disableStitch: boolean;
  isAIGC: boolean;
  brandContent: boolean;
  brandOrganic: boolean;
  musicTrackId: string | null;
}

/**
 * Fields are separated by a byte none of them can contain, so no combination of
 * values can be rearranged into the same string as a different combination -- a
 * caption ending in a comma must not be able to impersonate a caption plus a
 * hashtag.
 */
export async function contentDigest(input: DigestInput): Promise<string> {
  const flags = [
    input.disableComment,
    input.disableDuet,
    input.disableStitch,
    input.isAIGC,
    input.brandContent,
    input.brandOrganic,
  ]
    .map((flag) => (flag ? "1" : "0"))
    .join("");

  const parts = [
    "v1",
    input.platform,
    input.providerUserId,
    input.caption,
    input.hashtags.join(","),
    // Ordered, because the order they appear in a carousel is part of the post.
    input.variantChecksums.join(","),
    input.privacy,
    flags,
    input.musicTrackId ?? "",
  ];

  const encoded = new TextEncoder().encode(parts.join(SEPARATOR));
  const hash = await crypto.subtle.digest("SHA-256", encoded);

  return Array.from(new Uint8Array(hash), (b) => b.toString(16).padStart(2, "0")).join("");
}

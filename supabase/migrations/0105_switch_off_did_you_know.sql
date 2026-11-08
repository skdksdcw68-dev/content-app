-- "Did you know" is off (Abel, 8 Nov 2026: "remove did you know"). Switched off,
-- never deleted: `enabled = true` brings it back, and archived plans that name
-- it keep their slug.
update content_templates set enabled = false where slug = 'facts';

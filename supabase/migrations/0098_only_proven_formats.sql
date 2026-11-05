-- Only the formats we have proven are offered: Did you know, Scary stories and
-- Motivation (Abel, 5 Nov 2026: "switch off all 33 other styles"). The 3D story
-- (`cutscene`, 0097) stays off until its reference pictures pass.
--
-- Switched off, never deleted: a style comes back with `enabled = true`, and
-- archived plans that name one keep their slug.
update content_templates set enabled = (slug in ('facts', 'scary', 'motivation'));

-- The pictures of one request may run side by side in their thread.
--
-- 0002 allowed one queued-or-running run per thread, so two agents could not
-- plan the same conversation at once. A request for four pictures starts four
-- runs in one thread (agent-chat `startBatch`): the first took the slot, this
-- index refused the other three, and agent-chat skipped them without a word.
-- "4 different images" delivered one. (Abel, 1 Nov 2026)
--
-- A run that belongs to a set carries `input.batch`, and is outside the rule.
-- Everything else is held to one live run per thread, as before.
drop index if exists agent_runs_one_live_idx;

create unique index agent_runs_one_live_idx on agent_runs (thread_id)
  where status in ('queued', 'running')
    and not coalesce(input ? 'batch', false);

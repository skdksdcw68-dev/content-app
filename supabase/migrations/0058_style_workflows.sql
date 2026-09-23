-- 0058: many more styles, and a planned workflow for each.
--
-- Abel, 23 Sep 2026: "this content isn't good enough, we need a lot, and we
-- need to plan each of their workflows." A style now says how its videos get
-- made, not just what they are about:
--
--   format     narrated | text_on_screen | talking_head | b_roll | demo | slideshow
--   structure  the beats every video follows, in order, with rough timings
--   shots      how many shots the concept lists
--   voice      narration | on_camera | none
--   text       captions | big_text | none
--   music      the mood
--   hooks      opening patterns the writer rotates through
--   duration_s the length when the person says "decide for me"
--   steps      how every video gets made, the way the app explains it
--
-- The writer reads format, structure, shots, voice, text and hooks; the
-- render loop reads duration_s; the app shows steps on the review screen.
-- Steps that are not automated yet (voice-over, captions, music) are still
-- written down here: they are the plan the pipeline grows into.

alter table content_templates add column if not exists workflow jsonb not null default '{}';

insert into content_templates (slug, name, tagline, category, brief, pillars, visual_style, symbol, sort, workflow) values

-- ------------------------------------------------------------------ Stories
('scary', 'Scary stories', 'Short, unsettling, a twist at the end.', 'Stories',
 'Short scary stories, urban legends and unsettling true facts, told calmly, each ending on a twist or an open question.',
 '[{"name":"Urban legends","detail":"A legend told as if it happened last week."},{"name":"True-crime facts","detail":"One real, documented case in 40 seconds."},{"name":"Things that do not add up","detail":"A mystery with no clean explanation."},{"name":"Two-sentence horror","detail":"Set-up, then the line that turns it."}]',
 'dark and moody, slow push-ins, dim interiors and empty night streets, high contrast, film grain, no faces in focus', 'moon.stars', 10,
 '{"format":"narrated","structure":["Hook (0-3s): the strangest line of the story, said flat","Set-up (3-15s): where, who, the ordinary detail","Turn (15-35s): the thing that is wrong","Last line (35-45s): the twist, then silence"],"shots":4,"voice":"narration","text":"captions","music":"low drone, no melody","hooks":["Nobody talks about what happened at…","The last message she sent was…","There is one detail the police never explained."],"duration_s":45,"steps":["Write the story from a real or legend source","Make 4 dark, slow shots in the style","Narrate it in a calm voice","Add captions, word by word","Post at night"]}'),

('storytime', 'Story time', 'Something that happened, and what it taught.', 'Stories',
 'Personal stories from the account: something that happened, the turning point, and the lesson, told to one person.',
 '[{"name":"Something that happened","detail":"A moment, told straight."},{"name":"Lessons learned","detail":"What it changed."},{"name":"The turning point","detail":"The day it turned."}]',
 'warm interior, one subject talking, soft window light, intimate framing', 'book', 20,
 '{"format":"talking_head","structure":["Hook (0-3s): the end of the story first","The story (3-40s): what happened, in order","The lesson (40-50s): one sentence"],"shots":2,"voice":"on_camera","text":"captions","music":"soft, warm, quiet","hooks":["I almost quit the day that…","This is the story of how…","I never told anyone this."],"duration_s":50,"steps":["Write the story in first person","One talking shot, one cutaway","Captions","Post"]}'),

('mystery', 'Unsolved mysteries', 'The case, the clues, the question.', 'Stories',
 'Unsolved cases and unexplained events, laid out as clues, ending on the question nobody has answered.',
 '[{"name":"The case","detail":"What is known, in order."},{"name":"The clue","detail":"One detail that changes it."},{"name":"The theories","detail":"Two, and why each fails."}]',
 'archive photographs, maps, slow zooms, desaturated, evidence-board feel', 'magnifyingglass', 30,
 '{"format":"narrated","structure":["Hook (0-3s): the unexplained fact","The case (3-25s): the facts, dated","The clue (25-40s): the detail that does not fit","The question (40-45s): what nobody can answer"],"shots":4,"voice":"narration","text":"captions","music":"tense, sparse","hooks":["In 19xx, … and then nothing.","Every theory has the same hole.","The file is still open."],"duration_s":45,"steps":["Research one documented case","Make 4 evidence-style shots","Narrate","Captions","Post"]}'),

('history', 'History in a minute', 'One event, compressed.', 'Stories',
 'One historical event or person per video, compressed to a minute, with the detail history books skip.',
 '[{"name":"The event","detail":"What happened, in order."},{"name":"The person","detail":"One life, one turn."},{"name":"The detail","detail":"The thing the books skip."}]',
 'period paintings and photographs, slow pans, sepia and black and white, maps', 'building.columns', 40,
 '{"format":"narrated","structure":["Hook (0-3s): the surprising outcome","Context (3-15s): where and when","What happened (15-45s): the sequence","The detail (45-55s): the thing they skip"],"shots":5,"voice":"narration","text":"captions","music":"orchestral, restrained","hooks":["Everyone knows the ending; nobody knows why.","It took one afternoon to change…","The map still shows it."],"duration_s":55,"steps":["Research one event","Make 5 period-style shots","Narrate","Captions with dates","Post"]}'),

-- ----------------------------------------------------------------- Learning
('facts', 'Did you know', 'Surprising facts, told fast.', 'Learning',
 'Surprising, checkable facts about the world, told fast with one clear image per fact, ending on the detail nobody expects.',
 '[{"name":"Surprising facts","detail":"One fact, one image, one payoff."},{"name":"History in 30 seconds","detail":"An event, compressed."},{"name":"Science you can feel","detail":"Something physical you can try."},{"name":"Numbers that surprise","detail":"A figure and what it means."}]',
 'clean b-roll, close-ups of real objects, satisfying macro shots, bright even light, no text on screen', 'lightbulb', 50,
 '{"format":"narrated","structure":["Hook (0-2s): the fact as a question","The fact (2-15s): said once, shown once","Why (15-25s): the reason","Payoff (25-30s): the detail nobody expects"],"shots":3,"voice":"narration","text":"big_text","music":"light, curious","hooks":["Why does … ?","Most people think … It is the opposite.","This is why …"],"duration_s":30,"steps":["Pick one checkable fact","Make 3 clean shots","Narrate","Big text for the number","Post"]}'),

('tips', 'Tips and tricks', 'One trick per video.', 'Learning',
 'Practical tips in the account''s field: one trick per video, mistakes to avoid, tools worth knowing, and shortcuts that hold up.',
 '[{"name":"One trick","detail":"A single move, shown."},{"name":"Mistakes to avoid","detail":"What people get wrong."},{"name":"Tools","detail":"One tool, one use."},{"name":"Shortcuts","detail":"The faster way."}]',
 'clean desk and hands, over-the-shoulder shots, bright and simple, quick cuts', 'wrench.and.screwdriver', 60,
 '{"format":"demo","structure":["Hook (0-3s): the result first","The trick (3-20s): shown step by step","Why it works (20-25s)"],"shots":3,"voice":"narration","text":"captions","music":"upbeat, light","hooks":["Stop doing … Do this.","The fastest way to …","Nobody taught you this."],"duration_s":25,"steps":["Pick one trick","Make 3 over-the-shoulder shots","Narrate the steps","Captions","Post"]}'),

('myths', 'Myth busting', 'What people believe, and what is true.', 'Learning',
 'Common myths in the account''s field and what is actually true, said plainly with one reason each.',
 '[{"name":"Common myths","detail":"The belief, then the fact."},{"name":"What actually works","detail":"The thing that does."},{"name":"Ask the expert","detail":"A question people keep asking."}]',
 'clean backdrops, split scenes, direct to camera, bright even light', 'xmark.seal', 70,
 '{"format":"talking_head","structure":["Hook (0-3s): the myth, said as if true","The turn (3-6s): actually, no","The truth (6-25s): with one reason","What to do instead (25-30s)"],"shots":2,"voice":"on_camera","text":"big_text","music":"none","hooks":["You have been told … It is wrong.","Myth: … Truth: …","Stop believing this."],"duration_s":30,"steps":["Pick one myth","Talking shot plus one cutaway","Big text: MYTH / TRUTH","Post"]}'),

('compare', 'This vs that', 'Two options, one honest verdict.', 'Learning',
 'Comparisons in the account''s field: two options side by side, cheap against expensive, then against now, with a verdict.',
 '[{"name":"Two options","detail":"A and B, honestly."},{"name":"Cheap vs expensive","detail":"Where the money goes."},{"name":"Then vs now","detail":"How it changed."}]',
 'side-by-side and split-screen compositions, matching angles, clean backgrounds', 'scalemass', 80,
 '{"format":"b_roll","structure":["Hook (0-3s): the two, named","A (3-15s): what it does well","B (15-27s): what it does well","Verdict (27-35s): which, for whom"],"shots":4,"voice":"narration","text":"big_text","music":"neutral, steady","hooks":["… or …? Here is the answer.","I used both for a month.","Same price. Not the same thing."],"duration_s":35,"steps":["Pick two things people actually choose between","Make matching shots of each","Narrate","Big text labels A and B","Post"]}'),

('explainer', 'Explain it simply', 'One idea, explained like to a friend.', 'Learning',
 'One idea from the account''s field per video, explained the way you would to a friend, with one everyday comparison.',
 '[{"name":"How it works","detail":"The mechanism, plainly."},{"name":"The comparison","detail":"Like … for …"},{"name":"Why it matters","detail":"What changes if you know it."}]',
 'simple animated-feel shots, clean shapes on plain backgrounds, one object at a time', 'questionmark.circle', 90,
 '{"format":"narrated","structure":["Hook (0-3s): the question","The comparison (3-15s): it is like…","How it works (15-35s)","Why it matters (35-40s)"],"shots":3,"voice":"narration","text":"captions","music":"light, thoughtful","hooks":["Here is how … actually works.","Think of it like…","Nobody explains this properly."],"duration_s":40,"steps":["Pick one idea","Find the everyday comparison","3 simple shots","Narrate","Captions","Post"]}'),

('language', 'Learn a phrase', 'One phrase a day.', 'Learning',
 'One useful phrase or word per video in the language the account teaches: how it sounds, what it means, when to use it.',
 '[{"name":"One phrase","detail":"Said, spelled, used."},{"name":"Mistakes learners make","detail":"The common slip."},{"name":"Real situations","detail":"At the shop, at the door."}]',
 'bright, friendly, one person speaking to camera, plain background', 'character.book.closed', 100,
 '{"format":"talking_head","structure":["Hook (0-2s): the phrase, said","Meaning (2-10s)","Use it (10-20s): a real situation","Say it again (20-25s)"],"shots":1,"voice":"on_camera","text":"big_text","music":"none","hooks":["Say this instead of …","One phrase you will use every day.","Locals never say …"],"duration_s":25,"steps":["Pick one phrase","One talking shot","Big text with the spelling","Post"]}'),

-- ----------------------------------------------------------------- Business
('product', 'Show the product', 'Demos, before and after, behind the scenes.', 'Business',
 'Show what the product does and who it is for: demos, a problem it solves, before and after, and honest behind-the-scenes.',
 '[{"name":"Demo","detail":"One feature, start to finish."},{"name":"Before and after","detail":"The same task, without and with."},{"name":"A problem it solves","detail":"Start from the annoyance."},{"name":"Behind the scenes","detail":"How it is actually made."}]',
 'clean studio product shots, hands using the product, bright even light, neutral backgrounds, shallow depth of field', 'shippingbox', 110,
 '{"format":"demo","structure":["Hook (0-3s): the annoyance","The product (3-20s): doing the one thing","The result (20-28s)","Where to get it (28-30s)"],"shots":3,"voice":"narration","text":"captions","music":"clean, modern","hooks":["If you still … you need this.","Watch what happens when…","This took me 10 seconds."],"duration_s":30,"steps":["Pick one feature","3 clean product shots","Narrate","Captions","Post with the link"]}'),

('founder', 'Founder diary', 'Building it, in the open.', 'Business',
 'The person behind the product, building in the open: what was worked on, what broke, what was learned, real numbers only when they are written down.',
 '[{"name":"What I worked on","detail":"Today, honestly."},{"name":"What broke","detail":"And what it cost."},{"name":"What I learned","detail":"One line."},{"name":"Ask me","detail":"A question from the comments."}]',
 'desk, screen glow, late light, handheld, honest and unpolished', 'laptopcomputer', 120,
 '{"format":"talking_head","structure":["Hook (0-3s): the day in one line","What happened (3-30s)","What it taught (30-40s)"],"shots":2,"voice":"on_camera","text":"captions","music":"lo-fi, quiet","hooks":["Day … of building …","Today went wrong.","Here is the number nobody shares."],"duration_s":40,"steps":["Write the day from real notes","One talking shot, one desk shot","Captions","Post"]}'),

('marketing', 'Marketing lessons', 'What works, shown on real examples.', 'Business',
 'Marketing and growth lessons shown on real, named examples: a hook that worked, a page that converts, an ad that failed.',
 '[{"name":"A hook that worked","detail":"And why."},{"name":"Pages that convert","detail":"One element."},{"name":"Ads that failed","detail":"The lesson."},{"name":"Numbers","detail":"Only ones written down."}]',
 'screen recordings framed on a desk, clean, bright, quick cuts', 'chart.line.uptrend.xyaxis', 130,
 '{"format":"b_roll","structure":["Hook (0-3s): the result","The example (3-20s): on screen","The principle (20-30s)","Try it (30-35s)"],"shots":3,"voice":"narration","text":"big_text","music":"upbeat, clean","hooks":["This one line doubled …","Why this ad worked.","Steal this."],"duration_s":35,"steps":["Pick one real example","Screen shots of it","Narrate the principle","Big text for the takeaway","Post"]}'),

('ecommerce', 'Shop finds', 'The product, in use, honestly.', 'Business',
 'Products from the shop shown in use: unboxing, the detail that sells it, how it is packed, what people ask.',
 '[{"name":"Unboxing","detail":"The first ten seconds."},{"name":"The detail","detail":"The thing that sells it."},{"name":"Packing an order","detail":"Satisfying, real."},{"name":"Questions people ask","detail":"Answered on camera."}]',
 'bright tabletop, hands, satisfying close-ups, warm light', 'bag', 140,
 '{"format":"demo","structure":["Hook (0-3s): the reveal","In use (3-20s)","The detail (20-27s)","Get it (27-30s)"],"shots":3,"voice":"none","text":"big_text","music":"trending, upbeat","hooks":["POV: your order arrives.","The detail nobody notices.","Packing your order."],"duration_s":30,"steps":["Pick one product","3 tabletop shots","Big text","Trending sound","Post"]}'),

-- ---------------------------------------------------------------- Lifestyle
('dayinlife', 'Day in the life', 'Real days, one small thing at a time.', 'Lifestyle',
 'A day in the life of the person behind the account: mornings, work, evenings, and one small thing that made the day.',
 '[{"name":"Morning","detail":"How the day starts."},{"name":"Work","detail":"The middle of it, honestly."},{"name":"Evening","detail":"Winding down."},{"name":"One small thing","detail":"The detail that made today."}]',
 'handheld point-of-view, natural light, real rooms and streets, unpolished, warm', 'sun.max', 150,
 '{"format":"b_roll","structure":["Hook (0-3s): the time, the first shot","The day (3-40s): 5 moments in order","The small thing (40-45s)"],"shots":6,"voice":"narration","text":"captions","music":"calm, acoustic","hooks":["6am. Here is the day.","A normal Tuesday.","Come with me."],"duration_s":45,"steps":["Note 5 moments of the day","6 handheld shots","Light narration","Captions with times","Post"]}'),

('luxury', 'Luxury lifestyle', 'Cars, homes, travel, habits.', 'Lifestyle',
 'Aspirational lifestyle: cars, homes, travel and the habits behind them, shown rather than bragged.',
 '[{"name":"Cars","detail":"One car, one detail."},{"name":"Homes","detail":"A room worth seeing."},{"name":"Travel","detail":"A place, at its best hour."},{"name":"Habits of the rich","detail":"What they actually do."}]',
 'glossy, golden hour, slow gimbal moves, reflections, polished surfaces', 'crown', 160,
 '{"format":"b_roll","structure":["Hook (0-3s): the reveal shot","The thing (3-25s): slow, three angles","The line (25-30s): one sentence"],"shots":4,"voice":"none","text":"big_text","music":"cinematic, slow","hooks":["This is what … looks like.","Nobody shows you this part.","Worth every…"],"duration_s":30,"steps":["Pick one subject","4 slow gimbal shots at golden hour","One line of big text","Cinematic sound","Post"]}'),

('pets', 'Pets and animals', 'Funny, cute, and a fact or two.', 'Lifestyle',
 'Pets and animals: funny moments, facts about animals, and small cute wins, kept light.',
 '[{"name":"Funny moments","detail":"The thing it did."},{"name":"Facts about animals","detail":"One fact, one animal."},{"name":"Cute wins","detail":"A small good moment."}]',
 'bright, playful, close-ups at animal eye level, natural light', 'pawprint', 170,
 '{"format":"b_roll","structure":["Hook (0-2s): the face","The moment (2-15s)","The line (15-20s)"],"shots":2,"voice":"none","text":"big_text","music":"playful, trending","hooks":["He does this every morning.","Wait for it.","Nobody told me they…"],"duration_s":20,"steps":["Pick one moment","2 eye-level shots","Big text","Trending sound","Post"]}'),

('travel', 'Travel', 'A place, at its best hour.', 'Lifestyle',
 'Places worth going: one place per video, the hour it looks best, what to do there, and one thing people get wrong.',
 '[{"name":"One place","detail":"At its best hour."},{"name":"What to do","detail":"Three things."},{"name":"What people get wrong","detail":"The tourist mistake."},{"name":"How much","detail":"Only if written down."}]',
 'wide establishing shots, golden hour, slow walks, street level, no people in focus', 'airplane', 180,
 '{"format":"narrated","structure":["Hook (0-3s): the widest shot","Where (3-8s)","Three things (8-30s)","The mistake (30-38s)","Go (38-40s)"],"shots":5,"voice":"narration","text":"captions","music":"warm, wandering","hooks":["Skip … Go here.","The best hour to see …","Everyone gets this wrong in …"],"duration_s":40,"steps":["Pick one place","5 wide and walking shots","Narrate","Captions with names","Post"]}'),

('food', 'Food', 'One dish, made or found.', 'Lifestyle',
 'Food: one dish per video, made from start to finish or found somewhere worth naming, with the one step that matters.',
 '[{"name":"Make it","detail":"Start to finish, fast."},{"name":"The one step","detail":"Where it goes right or wrong."},{"name":"Found it","detail":"A place worth naming."},{"name":"Ingredients","detail":"What actually matters."}]',
 'overhead and close-up, steam, sizzle, warm light, fast satisfying cuts', 'fork.knife', 190,
 '{"format":"b_roll","structure":["Hook (0-3s): the finished dish","Make it (3-25s): the steps, fast","The one step (25-32s)","Eat (32-35s)"],"shots":5,"voice":"none","text":"big_text","music":"upbeat, kitchen","hooks":["The only … recipe you need.","Do not skip this step.","10 minutes. That is it."],"duration_s":35,"steps":["Pick one dish","5 overhead and close shots","Big text for steps","Sound","Post"]}'),

('fitness', 'Fitness', 'One exercise, done right.', 'Health',
 'Training and fitness: one exercise per video done right and wrong, short routines, and honest progress without promises.',
 '[{"name":"One exercise","detail":"Right, then the common wrong."},{"name":"Short routines","detail":"5 minutes, real."},{"name":"Progress","detail":"Only what is written down."},{"name":"Myths","detail":"The gym belief that fails."}]',
 'gym floor, side angle, clean, bright, real people mid-movement', 'figure.strengthtraining.traditional', 200,
 '{"format":"demo","structure":["Hook (0-3s): the mistake","Right (3-15s): the movement, slow","Wrong (15-22s): what to avoid","Reps (22-28s)"],"shots":3,"voice":"narration","text":"big_text","music":"driving, steady","hooks":["You are doing … wrong.","Fix this and it works.","30 seconds. Every day."],"duration_s":30,"steps":["Pick one movement","3 side-angle shots","Narrate the cue","Big text RIGHT / WRONG","Post"]}'),

('sleep', 'Sleep and recovery', 'What actually helps.', 'Health',
 'Sleep and recovery: what actually helps and what does not, one habit per video, said without promises.',
 '[{"name":"One habit","detail":"Tonight."},{"name":"What does not work","detail":"And why people do it."},{"name":"The science, simply","detail":"One mechanism."}]',
 'dim bedroom, warm lamps, slow, calm, blue hour', 'bed.double', 210,
 '{"format":"narrated","structure":["Hook (0-3s): the thing keeping you up","The habit (3-20s)","Why it works (20-28s)","Tonight (28-30s)"],"shots":3,"voice":"narration","text":"captions","music":"ambient, slow","hooks":["If you wake up at 3am…","Stop doing this before bed.","One change. Better sleep."],"duration_s":30,"steps":["Pick one habit","3 calm shots","Soft narration","Captions","Post in the evening"]}'),

('nutrition', 'Eat better', 'One food, one truth.', 'Health',
 'Nutrition without preaching: one food or habit per video, what it does, what the label hides, easy swaps.',
 '[{"name":"One food","detail":"What it does."},{"name":"Read the label","detail":"What it hides."},{"name":"Easy swaps","detail":"This for that."}]',
 'bright kitchen, clean surfaces, real food close-ups', 'leaf', 220,
 '{"format":"demo","structure":["Hook (0-3s): the label or the food","The truth (3-18s)","The swap (18-25s)"],"shots":3,"voice":"narration","text":"big_text","music":"light, fresh","hooks":["Read this label with me.","Swap this for this.","Nobody tells you what is in…"],"duration_s":25,"steps":["Pick one food","3 kitchen shots","Narrate","Big text for the swap","Post"]}'),

-- ------------------------------------------------------------------ Mindset
('motivation', 'Motivation', 'Discipline, small wins, hard truths.', 'Mindset',
 'Motivation for people building something: discipline over mood, small daily wins, hard truths said kindly, and routines that hold.',
 '[{"name":"Discipline","detail":"Doing it on the days you do not feel like it."},{"name":"Small wins","detail":"One thing done today."},{"name":"Hard truths","detail":"The uncomfortable line, said plainly."},{"name":"Morning routines","detail":"The first hour."}]',
 'cinematic, sunrise and golden hour, gym floors, running at dawn, city rooftops, warm light, slow steady camera', 'flame', 230,
 '{"format":"narrated","structure":["Hook (0-3s): the hard line","The truth (3-20s)","The turn (20-30s): what to do today","Last line (30-35s)"],"shots":4,"voice":"narration","text":"big_text","music":"cinematic build","hooks":["Nobody is coming to save you.","You do not need motivation. You need…","The day you stop… "],"duration_s":35,"steps":["Write the line first","4 dawn and gym shots","Narrate low and slow","Big text for the line","Post in the morning"]}'),

('quotes', 'Quotes and thoughts', 'A line worth remembering.', 'Mindset',
 'Short thoughts and quotes worth remembering, one per video, with a sentence on why it matters today.',
 '[{"name":"A line worth remembering","detail":"One sentence, held."},{"name":"Stoic thoughts","detail":"Old ideas for today."},{"name":"Words for today","detail":"Something to carry."}]',
 'slow landscapes, ocean and sky, minimal and calm, long takes, soft light', 'quote.bubble', 240,
 '{"format":"text_on_screen","structure":["The line (0-8s): on screen, held","Why (8-18s): one sentence","Carry it (18-20s)"],"shots":2,"voice":"none","text":"big_text","music":"ambient, calm","hooks":["Read this twice.","For anyone who needs it today.","Old words. Still true."],"duration_s":20,"steps":["Pick one line","2 slow landscape shots","Big text, held","Ambient sound","Post"]}'),

('stoic', 'Stoic mind', 'Old ideas for today.', 'Mindset',
 'Stoic and practical philosophy applied to one modern situation per video: the idea, the situation, the move.',
 '[{"name":"The idea","detail":"One, stated simply."},{"name":"The situation","detail":"Something that happened this week."},{"name":"The move","detail":"What a stoic does."}]',
 'stone, marble, statues, rain on windows, black and white, slow', 'figure.mind.and.body', 250,
 '{"format":"narrated","structure":["Hook (0-3s): the situation","The idea (3-15s)","The move (15-28s)","Last line (28-30s)"],"shots":3,"voice":"narration","text":"captions","music":"piano, sparse","hooks":["When someone insults you…","Marcus Aurelius had one rule for this.","Control what you can. Here is what that means."],"duration_s":30,"steps":["Pick one idea and one situation","3 black and white shots","Narrate","Captions","Post"]}'),

('productivity', 'Get more done', 'Systems, not hacks.', 'Mindset',
 'Productivity as systems: one method per video, how to set it up in five minutes, and where it breaks.',
 '[{"name":"One method","detail":"Set up in five minutes."},{"name":"Where it breaks","detail":"And the fix."},{"name":"Tools","detail":"One, and how."},{"name":"A week with it","detail":"Only what was written down."}]',
 'clean desk, notebook and screen, bright, calm, top-down', 'checklist', 260,
 '{"format":"demo","structure":["Hook (0-3s): the problem","The method (3-22s): shown","Where it breaks (22-28s)","Try it (28-30s)"],"shots":3,"voice":"narration","text":"captions","music":"lo-fi, focused","hooks":["Stop making to-do lists.","The system I use every day.","This takes five minutes to set up."],"duration_s":30,"steps":["Pick one method","3 desk shots","Narrate","Captions","Post"]}'),

-- -------------------------------------------------------------------- Money
('finance', 'Money, simply', 'One money idea, no jargon.', 'Money',
 'Personal finance without jargon: one idea per video, an example with round numbers, and the mistake most people make. No advice on specific investments.',
 '[{"name":"One idea","detail":"Saving, spending, debt."},{"name":"An example","detail":"Round numbers."},{"name":"The mistake","detail":"What most people do."},{"name":"Habits","detail":"One, monthly."}]',
 'clean, bright, coins and cards and receipts on a plain surface, top-down', 'banknote', 270,
 '{"format":"narrated","structure":["Hook (0-3s): the number","The idea (3-15s)","The example (15-25s)","The mistake (25-30s)"],"shots":3,"voice":"narration","text":"big_text","music":"light, clean","hooks":["Most people lose money here.","Here is what … actually costs.","One habit. Every month."],"duration_s":30,"steps":["Pick one idea","3 top-down shots","Narrate","Big text for numbers","Post"]}'),

('sidehustle', 'Side hustle', 'What it takes, honestly.', 'Money',
 'Side hustles and small businesses: what one takes to start, what it actually pays only when written down, and the first step.',
 '[{"name":"One hustle","detail":"What it is."},{"name":"What it takes","detail":"Time, money, skill."},{"name":"The first step","detail":"This week."},{"name":"What went wrong","detail":"Honestly."}]',
 'real workspaces, phones and laptops, packages, early mornings, handheld', 'briefcase', 280,
 '{"format":"talking_head","structure":["Hook (0-3s): the hustle in one line","What it takes (3-20s)","The first step (20-28s)","Go (28-30s)"],"shots":2,"voice":"on_camera","text":"captions","music":"upbeat, driving","hooks":["You could start this on Saturday.","Nobody tells you the boring part.","Step one is not what you think."],"duration_s":30,"steps":["Pick one hustle","Talking shot and one workspace shot","Captions","Post"]}'),

-- --------------------------------------------------------------------- Tech
('aitools', 'AI tools', 'One tool, one thing it does well.', 'Tech',
 'AI tools shown doing one useful thing each: the prompt, the result, and where it falls short.',
 '[{"name":"One tool","detail":"One task, shown."},{"name":"The prompt","detail":"Exactly what was typed."},{"name":"Where it fails","detail":"Honestly."},{"name":"Workflow","detail":"Two tools together."}]',
 'screen recordings framed on a desk, cursor visible, clean, quick', 'sparkles', 290,
 '{"format":"demo","structure":["Hook (0-3s): the result","The prompt (3-10s): typed","The result (10-22s)","Where it fails (22-28s)","Try (28-30s)"],"shots":3,"voice":"narration","text":"captions","music":"modern, clean","hooks":["This AI does … in 10 seconds.","Type this exact prompt.","It fails at one thing."],"duration_s":30,"steps":["Pick one tool and one task","Screen shots of prompt and result","Narrate","Captions","Post"]}'),

('apps', 'App of the day', 'One app, worth it or not.', 'Tech',
 'One app per video: what it does, the one screen that matters, and whether it is worth it.',
 '[{"name":"One app","detail":"What it does."},{"name":"The one screen","detail":"Where it earns its place."},{"name":"Worth it?","detail":"For whom."},{"name":"Hidden features","detail":"One."}]',
 'phone in hand, screen recording framed, bright, clean', 'apps.iphone', 300,
 '{"format":"demo","structure":["Hook (0-3s): the app, the claim","The screen (3-18s)","Worth it? (18-25s)","Get it (25-28s)"],"shots":2,"voice":"narration","text":"captions","music":"light, modern","hooks":["Delete … Get this instead.","The app I open every morning.","One feature nobody knows."],"duration_s":28,"steps":["Pick one app","Screen shots","Narrate","Captions","Post"]}'),

('gadgets', 'Gadgets', 'Hands on, no hype.', 'Tech',
 'Gadgets hands on: the one thing each does well, what it is missing, and whether to buy it. No specs without a reason.',
 '[{"name":"One gadget","detail":"Hands on."},{"name":"What it gets right","detail":"One thing."},{"name":"What is missing","detail":"Honestly."},{"name":"Buy or skip","detail":"For whom."}]',
 'desk, hands, close-up macro of buttons and ports, clean light', 'headphones', 310,
 '{"format":"demo","structure":["Hook (0-3s): the gadget in hand","Right (3-15s)","Missing (15-23s)","Buy or skip (23-28s)"],"shots":3,"voice":"narration","text":"captions","music":"clean, techy","hooks":["I used this for a week.","One thing it does better than anything.","Do not buy this if…"],"duration_s":28,"steps":["Pick one gadget","3 macro shots","Narrate","Captions","Post"]}'),

-- ------------------------------------------------------------ Entertainment
('trends', 'Trends and memes', 'The trend, your way.', 'Entertainment',
 'Current trends and formats done in the account''s own voice: the sound, the format, the twist that makes it yours.',
 '[{"name":"The trend","detail":"This week."},{"name":"Our twist","detail":"What makes it ours."},{"name":"Relatable","detail":"Something everyone has done."}]',
 'fast, bright, phone-native, quick cuts, big expressions', 'flame.fill', 320,
 '{"format":"b_roll","structure":["Hook (0-2s): the format, instantly recognisable","The twist (2-12s)","Punchline (12-15s)"],"shots":2,"voice":"none","text":"big_text","music":"trending sound","hooks":["POV: …","Tell me you … without telling me…","Nobody: … Me: …"],"duration_s":15,"steps":["Pick this week''s format","2 quick shots","Big text","Trending sound","Post"]}'),

('pov', 'POV', 'You are there.', 'Entertainment',
 'First-person point-of-view moments in the account''s world: the situation, the beat, the reaction.',
 '[{"name":"A situation","detail":"You are there."},{"name":"The beat","detail":"The moment it turns."},{"name":"The reaction","detail":"One line."}]',
 'first-person camera, hands in frame, natural light, handheld', 'eye', 330,
 '{"format":"b_roll","structure":["Hook (0-2s): POV: …","The beat (2-10s)","The reaction (10-14s)"],"shots":2,"voice":"none","text":"big_text","music":"trending or none","hooks":["POV: you finally…","POV: it is 7am and…","POV: someone says…"],"duration_s":15,"steps":["Pick one situation","2 first-person shots","Big text","Sound","Post"]}'),

('satisfying', 'Satisfying', 'No words. Just the thing.', 'Entertainment',
 'Oddly satisfying moments from the account''s world: cleaning, cutting, organising, finishing; no words, just the thing done well.',
 '[{"name":"Clean","detail":"Before, during, after."},{"name":"Cut","detail":"One clean cut."},{"name":"Organise","detail":"From mess to order."},{"name":"Finish","detail":"The last step."}]',
 'macro, steady, perfect lighting, slow and precise, satisfying textures', 'sparkle', 340,
 '{"format":"b_roll","structure":["Hook (0-2s): the mess or the start","The process (2-18s): steady, uncut where possible","The finish (18-20s)"],"shots":2,"voice":"none","text":"none","music":"ASMR sound of the thing","hooks":["","",""],"duration_s":20,"steps":["Pick one process","Steady macro shots","Real sound","Post"]}'),

('reactions', 'Hot takes', 'One opinion, defended in 30 seconds.', 'Entertainment',
 'Opinions in the account''s field, one per video, defended in thirty seconds with one reason and one counter.',
 '[{"name":"The take","detail":"One sentence."},{"name":"The reason","detail":"One."},{"name":"The counter","detail":"And the reply."}]',
 'direct to camera, tight framing, plain background, energetic', 'bubble.left.and.exclamationmark.bubble.right', 350,
 '{"format":"talking_head","structure":["Hook (0-3s): the take, said plainly","The reason (3-18s)","The counter (18-26s)","Last word (26-30s)"],"shots":1,"voice":"on_camera","text":"captions","music":"none","hooks":["Unpopular opinion: …","I will say it: …","Everyone is wrong about…"],"duration_s":30,"steps":["Write the take and the reason","One talking shot","Captions","Post"]}'),

-- ----------------------------------------------------------------- Creative
('process', 'The process', 'From blank to done.', 'Creative',
 'Creative work from blank to done: the first mark, the middle where it looks wrong, the finish; one piece per video.',
 '[{"name":"First marks","detail":"The blank page."},{"name":"The ugly middle","detail":"Where it looks wrong."},{"name":"The finish","detail":"The last five percent."},{"name":"Tools","detail":"One, and why."}]',
 'overhead of hands working, time-lapse feel, natural light, real studio mess', 'paintbrush', 360,
 '{"format":"b_roll","structure":["Hook (0-3s): the finished piece","Start (3-10s)","Middle (10-25s): where it looks wrong","Finish (25-35s)"],"shots":4,"voice":"none","text":"captions","music":"calm, acoustic","hooks":["It looked like this for two hours.","The part nobody posts.","From nothing to this."],"duration_s":35,"steps":["Pick one piece","4 overhead shots across the work","Light captions","Sound","Post"]}'),

('photography', 'Behind the photo', 'How the shot was made.', 'Creative',
 'How a photo or video was made: the location, the light, the settings only when written down, and the one decision that made it.',
 '[{"name":"The location","detail":"And the hour."},{"name":"The light","detail":"Where it came from."},{"name":"The decision","detail":"The one that made it."},{"name":"Before and after","detail":"The edit."}]',
 'the final image, then the scene behind it, camera in hand, golden hour', 'camera', 370,
 '{"format":"b_roll","structure":["Hook (0-3s): the final image","The scene (3-15s)","The decision (15-25s)","Before and after (25-30s)"],"shots":4,"voice":"narration","text":"captions","music":"soft, cinematic","hooks":["Here is how I got this shot.","Same place. Two hours apart.","One decision made this photo."],"duration_s":30,"steps":["Pick one photo","4 shots: final, scene, camera, edit","Narrate","Captions","Post"]}')

on conflict (slug) do update set
  name = excluded.name,
  tagline = excluded.tagline,
  category = excluded.category,
  brief = excluded.brief,
  pillars = excluded.pillars,
  visual_style = excluded.visual_style,
  symbol = excluded.symbol,
  sort = excluded.sort,
  workflow = excluded.workflow;

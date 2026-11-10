-- 0109: 3D stories written the way the videos that go viral are written.
--
-- Abel, 10 Nov 2026: "read the 3D explainers again, how they write the script
-- and make people excited ... make it a master prompt, we need to change the
-- crocodile ... use the voice I had on ElevenLabs ... different characters ...
-- make sure not to give everyone the same idea."
--
-- What his nine reference videos have in common (transcribed that day):
--   * the first sentence is already in the middle of something: a specific
--     someone, a strong verb, a strange object ("A man cut the legs off the
--     chair and added four springs", "If you stick your hand into a spinning
--     ceiling fan", "Most people think the brushes on escalators...");
--   * no greeting, no "did you know", no topic sentence;
--   * a chain, not a list: every sentence is caused by the one before and is
--     a new picture (but, so, then, instead, as soon as, that's why);
--   * "You see," / "In reality," once, then the mechanism in plain words with
--     one comparison (blades like hammers, Los Angeles to Long Beach);
--   * exact small numbers and physical nouns;
--   * it ENDS on the payoff: the most vivid image, the twist, the knot of the
--     paradox or the joke. No moral, no summary;
--   * 3 to 3.7 words a second, 40 to 230 words.
--
-- What was wrong before: the row's hooks and its one example were the
-- crocodile, and the only style reference frame was the crocodile video itself
-- (same woman, same river), so every 3D story drifted to a woman, a river and
-- a crocodile. Now: no crocodile anywhere, an idea bank of about 60 true or classic
-- starting points, a cast of twelve different adult heroes (one is drawn at
-- random per video by run-agent-jobs/story.ts), and Abel's own "Facts
-- narrator" voice.
--
-- Everything here is data: it changes without an app update.

update content_templates set
  tagline = 'Paradoxes, hidden reasons and true stories as a 3D animated short.',
  brief = 'A fast narrated short in a 3D animated look that hooks in the first second: a paradox or riddle told as a story, what really happens if you do something, the hidden reason behind an everyday object, a true story with an ending nobody expects, an animal fact that sounds made up, or an absurd joke told with a straight face. A different hero and a different world every time.',
  pillars = $j$[
    {"name":"Paradoxes and riddles","detail":"A deal, a trick question, a trap with no safe answer."},
    {"name":"What really happens","detail":"If you did it: the real mechanism, said plainly."},
    {"name":"The hidden reason","detail":"Everyday things everyone has seen and nobody can explain."},
    {"name":"True stories","detail":"Real events with an ending nobody expects."},
    {"name":"Animals","detail":"The fact that sounds made up and is true."},
    {"name":"Absurd jokes","detail":"An impossible little story with a straight face."}
  ]$j$::jsonb,
  visual_style = $v$a real-time 3D animated cutscene, Unreal or Blender look, NOT a photograph, NOT a cartoon, NOT big-eyed. People: realistic adult proportions, normal-size eyes, readable real expressions, smooth waxy airbrushed CG skin that is slightly doll-like with no pores and no wrinkles, simplified hair with a few loose strands, plain simple clothes. Light: warm low sun or one warm lamp from the side, a soft glow on the edges of people, animals and objects. Lens: very shallow focus, heavy creamy background blur, and a big out-of-focus object in the very front of the frame. Outdoors the sky is a bright saturated blue, water is glossy cobalt with sun sparkles and plants are lush and blurred; indoors the colours are just as saturated and clean. Animals and the key object are the most detailed things in the frame, glossy and lifelike. High saturation, a slight bloom. If a reference picture is attached it shows the RENDERING STYLE ONLY (skin, light, blur, colour): never copy its people, its animal or its place; draw only the people, animals and setting described here$v$,
  workflow = (workflow - 'hooks' - 'structure' - 'writer' - 'ideas' - 'cast') || jsonb_build_object(
    'duration_s', 30,
    'shots', 9,
    'writer_model', 'opus',
    'voice_id', 'aPgFuEb5k9kY4DTf3vFt',
    'voice_name', 'Facts narrator',
    'words_per_s', 2.7,
    'hooks', $j$[
      "A guard gave a traveller one sentence to save his life.",
      "If you fall into quicksand, the films have it wrong.",
      "The tiny hole in a plane window is not a mistake."
    ]$j$::jsonb,
    'structure', $j$[
      "First sentence (0-3s): already in the middle of it: someone, a strong verb, a strange object",
      "The chain (3-18s): each sentence caused by the last, each a new picture, the stakes rise once",
      "You see (18-25s): the mechanism or the trap, in the plainest words, with one comparison",
      "Payoff (last line): the most vivid image, the twist or the joke, and stop"
    ]$j$::jsonb,
    'cast', $j$[
      "a man in his early 30s, short black curly hair, dark-brown skin, slim build, mustard-yellow hoodie, black joggers, white trainers",
      "a woman in her mid 30s, dark hair in a messy bun, light-tan skin, cream V-neck t-shirt, grey cargo trousers, white trainers",
      "a man in his 50s, bald with a short grey beard, pale skin, heavy build, red flannel shirt, blue jeans, brown work boots",
      "a woman in her 40s, short silver bob, medium-brown skin, teal raincoat, black leggings, yellow rubber boots",
      "a man in his late 20s, ginger hair and beard, freckled pale skin, red knit hat, dark-green parka, grey trousers",
      "a woman in her late 20s, long black braids, deep-brown skin, orange puffer vest over a white long-sleeve top, blue jeans",
      "a man in his 40s, East Asian, neat black hair and round glasses, navy polo shirt, khaki shorts, brown sandals",
      "a woman in her 60s, white curly hair, light skin with rosy cheeks, purple cardigan, long grey skirt, brown lace-up shoes",
      "a man in his 30s, South Asian, thick black moustache, wavy black hair, sky-blue short-sleeve shirt, beige trousers, black shoes",
      "a woman in her 30s, olive-green headscarf, light-brown skin, beige trench coat, black trousers, white trainers",
      "a big man in his 40s, shaved head, tan skin, broad shoulders, black tank top, grey sweat shorts, red trainers",
      "a woman in her 50s, red hair in a ponytail, freckles, denim overalls over a white t-shirt, yellow work boots"
    ]$j$::jsonb,
    'ideas', $j$[
      {"kind":"paradox","seed":"A guard at a bridge hangs anyone who lies about where they are going. A traveller says: I am going to be hanged on this bridge. Whatever the guard does is wrong."},
      {"kind":"paradox","seed":"A village barber shaves every man who does not shave himself, and nobody else. So who shaves the barber?"},
      {"kind":"paradox","seed":"A teacher promises a surprise test next week. A student proves it cannot happen on any day, and is then surprised on Wednesday."},
      {"kind":"riddle","seed":"Two doors, two guards: one always lies, one always tells the truth, one question allowed. The question that works: which door would the other guard say is safe? Then take the opposite one."},
      {"kind":"paradox","seed":"A sailor replaces one rotten plank of his ship every year until no original plank is left. Is it still the same ship? And what if someone rebuilt the old planks into a second ship?"},
      {"kind":"riddle","seed":"A game show with three doors and one prize. After you pick, the host opens an empty door and offers a swap. Swapping wins two times out of three."},
      {"kind":"riddle","seed":"Two thieves are questioned in separate rooms. Each is offered a deal to betray the other. Both staying silent is best for both, yet both betraying is what usually happens."},
      {"kind":"paradox","seed":"A fast runner gives a tortoise a head start. Every time he reaches where the tortoise was, it has moved a little further, so on paper he never catches it."},
      {"kind":"riddle","seed":"A farmer must cross a river with a wolf, a goat and a cabbage in a boat that holds only one of them at a time. Left alone, the wolf eats the goat and the goat eats the cabbage."},
      {"kind":"riddle","seed":"A man asks a king for one grain of rice on the first square of a chessboard, doubled on every next square. By the last square the king owes more rice than exists on Earth."},
      {"kind":"paradox","seed":"A hungry donkey stands exactly between two identical piles of hay and cannot find a reason to choose one. The thought experiment says it starves."},
      {"kind":"what really happens","seed":"In a room of only 23 people there is about a fifty percent chance two share a birthday. It feels wrong because we think about our own birthday, not every possible pair."},
      {"kind":"what really happens","seed":"If you could fold a sheet of paper in half 42 times, the stack would be thick enough to reach the Moon, because doubling grows faster than anyone expects."},
      {"kind":"what really happens","seed":"If you fall into quicksand you cannot sink all the way under: it is denser than your body, so you float at about waist height. The danger is being stuck, and slow wiggling is what frees your legs."},
      {"kind":"what really happens","seed":"If lightning hits a car, the people inside are usually unharmed, because the metal body carries the current around them and into the ground."},
      {"kind":"what really happens","seed":"When your fingers wrinkle in water it is not the skin soaking. Nerves tighten the blood vessels on purpose, and the wrinkles grip wet things better, like tyre treads."},
      {"kind":"what really happens","seed":"When you chop an onion, damaged cells release a gas that turns into a mild acid on the wet surface of your eyes, so your eyes flood to wash it out."},
      {"kind":"what really happens","seed":"Brain freeze: something very cold on the roof of your mouth makes blood vessels there tighten and then widen fast, and nearby nerves report it as pain in the forehead."},
      {"kind":"what really happens","seed":"A hiccup is your diaphragm jerking down by mistake while your vocal cords slam shut a split second later, which makes the sound."},
      {"kind":"what really happens","seed":"When you stand up too fast and see sparkles, gravity has pulled blood toward your legs and your brain is short of it for a second or two."},
      {"kind":"what really happens","seed":"You are about a centimetre taller in the morning than at night, because the soft discs in your spine are squeezed by gravity all day and refill while you lie down."},
      {"kind":"what really happens","seed":"Goosebumps are tiny muscles pulling each hair upright. On our furry ancestors that trapped warm air and made them look bigger; on us it does almost nothing."},
      {"kind":"what really happens","seed":"You cannot breathe and swallow at the same moment: a small flap closes your windpipe each time you swallow so food goes the other way."},
      {"kind":"hidden reason","seed":"The tiny hole near the bottom of a plane window balances air pressure between the panes, so the strong outer pane takes the load, and it keeps the window from fogging."},
      {"kind":"hidden reason","seed":"The tiny pocket inside the front pocket of jeans was made in the 1800s to hold a pocket watch."},
      {"kind":"hidden reason","seed":"The ridges on the edge of many coins come from the days of gold and silver coins, when people shaved metal off smooth edges. Ridges made the theft visible."},
      {"kind":"hidden reason","seed":"The small hole in the bottom of a padlock lets rainwater drain out so it does not rust or freeze, and lets you oil the lock."},
      {"kind":"hidden reason","seed":"The extra top eyelet on running shoes is for a heel-lock lacing loop that stops your heel from sliding and rubbing."},
      {"kind":"hidden reason","seed":"The little arrow next to the fuel pump symbol on a car dashboard points to the side of the car the fuel cap is on."},
      {"kind":"hidden reason","seed":"The small bumps on the F and J keys let your index fingers find their home position without looking."},
      {"kind":"hidden reason","seed":"Manhole covers are round because a round lid cannot fall through its own hole, whichever way it is turned. A square one can, diagonally."},
      {"kind":"hidden reason","seed":"A golf ball has dimples because a rough surface keeps the air hugging the ball longer and cuts drag: a dimpled ball flies roughly twice as far as a smooth one."},
      {"kind":"hidden reason","seed":"The brushes along the sides of an escalator are there to keep feet, laces and trouser legs away from the gap at the edge, where things get caught."},
      {"kind":"hidden reason","seed":"Aeroplane seats must be upright for take-off and landing because that is when most accidents happen, and an upright seat keeps the row behind free to get out fast."},
      {"kind":"animal","seed":"An opossum playing dead is not acting. It faints from fear, goes stiff, drools and smells rotten for minutes or hours, and cannot choose when to wake up."},
      {"kind":"animal","seed":"An octopus has three hearts and blue blood, and the heart that feeds its body stops while it swims, which is why it prefers to crawl."},
      {"kind":"animal","seed":"Crows remember human faces. In a university study, crows scolded a mask worn by people who had trapped them years earlier, and crows that were never trapped joined in."},
      {"kind":"animal","seed":"Sea otters hold paws while they sleep on their backs so the current does not carry them away from each other."},
      {"kind":"animal","seed":"A hippo oozes a red, oily fluid that looks like blood. It works as sunscreen and fights germs."},
      {"kind":"animal","seed":"Wombats leave cube-shaped droppings. The walls of the gut stretch unevenly and form flat sides and corners, and the cubes do not roll off the rocks they mark."},
      {"kind":"animal","seed":"A pistol shrimp snaps its claw so fast it fires a bubble. When the bubble collapses it makes a loud crack and, for an instant, a point hotter than lava, stunning small prey."},
      {"kind":"animal","seed":"Koala fingerprints are so close to human ones that even under a microscope they are hard to tell apart."},
      {"kind":"animal","seed":"Flamingos are born grey. They turn pink from pigments in the shrimp and algae they eat."},
      {"kind":"animal","seed":"A mantis shrimp punches with one of the fastest strikes in nature, hard enough to crack a crab shell and sometimes aquarium glass."},
      {"kind":"animal","seed":"A giraffe has the same number of neck bones as a human, seven. Each one is just enormous."},
      {"kind":"true story","seed":"In 1932 Australia sent soldiers with machine guns against thousands of emus eating farm crops. The birds scattered and outran them, and the army gave up. It is known as the Emu War."},
      {"kind":"true story","seed":"In 1849 an enslaved man in Virginia, Henry Brown, had himself nailed into a wooden crate and shipped 27 hours to Philadelphia, to freedom."},
      {"kind":"true story","seed":"In 1964 an Australian athlete with no money for a ticket home from London, Reg Spiers, had a friend post him in a wooden crate as air freight. He arrived alive after about three days."},
      {"kind":"true story","seed":"In the Second World War Polish soldiers adopted a bear cub named Wojtek. He grew up, was enlisted with a rank, and carried heavy crates of ammunition during a battle in Italy."},
      {"kind":"true story","seed":"In 1518 in Strasbourg a woman began dancing in the street and could not stop. Within weeks hundreds had joined, for days on end. Nobody is sure why."},
      {"kind":"true story","seed":"In 1918 a carrier pigeon named Cher Ami, shot through the chest and leg, still delivered the message that saved nearly 200 trapped American soldiers."},
      {"kind":"true story","seed":"At the 1904 Olympic marathon the first man across the line had ridden part of the way in a car. He was found out before the medal was hung on him."},
      {"kind":"true story","seed":"In 1945 a farmer's axe missed most of a chicken's brain stem. The chicken, later called Mike, lived for 18 months without a head, fed with a dropper."},
      {"kind":"true story","seed":"In 1814 a huge vat burst at a London brewery and a wave of beer flooded the streets around it."},
      {"kind":"absurd joke","seed":"A man tired of walking to work bolts wheels and a lawnmower engine to his bed, and wakes up three towns away."},
      {"kind":"absurd joke","seed":"A woman trains her houseplant to answer the phone, and now it will not stop ordering pizza."},
      {"kind":"absurd joke","seed":"A man builds an umbrella so big that it never rains on his street again, and his neighbours start charging him for the weather."},
      {"kind":"absurd joke","seed":"A baker makes a loaf so fluffy it floats away, and now the town's bread is delivered by fishing rod."},
      {"kind":"absurd joke","seed":"A man installs a trampoline instead of stairs to save time, and has not been seen on the ground floor since."}
    ]$j$::jsonb,
    'writer', $w$THIS FORMAT
A 3D animated short that makes a stranger stop scrolling in the first second and stay for the answer. Pick the ONE kind that fits the topic:
1. PARADOX OR RIDDLE: a deal, a trick question or a trap with no safe answer, told as a small story, ending on the knot or on its answer.
2. WHAT REALLY HAPPENS: "If you..." or "When you..." puts the viewer's own body or belongings in the situation, then the real mechanism.
3. THE HIDDEN REASON: an everyday object or habit everyone has seen and nobody can explain.
4. TRUE STORY: a real, checkable event with an ending nobody expects.
5. ANIMAL: one animal doing the thing that sounds made up and is true.
6. ABSURD JOKE: an impossible little story told with a straight face, 10 to 15 seconds, ending on a silly last image. Obviously a joke, never passed off as fact.

THE FIRST SENTENCE (the whole video depends on it)
- It drops us into the middle of something already happening: a specific someone, a strong verb and a strange object within the first seven words.
- Three shapes that work. Write your own words, never these:
  a story already moving: "A baker locked his bread in a safe every night."
  the viewer in the situation: "If you fall into quicksand, do not do what the films show."
  the wrong belief: "Most people think the tiny pocket in their jeans is for coins."
- It must plant a question the viewer needs answered: why did he do that, what happens next, what is it really for.
- NEVER open with a greeting, "Did you know", "Imagine", "Have you ever wondered", "In this video", "Here's why", "Let me tell you", "Meet", a name and an age, the weather, the time of day or any background. Never a topic sentence.

THE MIDDLE (a chain, not a list)
- Every sentence is the direct result of the one before it and is a new picture. Join them the way people talk: but, so, then, instead, as soon as, meanwhile, that's why, which means.
- Make it worse, closer or stranger at least once before it is answered.
- Before the explanation turn to the viewer ONCE with "You see," or "In reality," and give the mechanism in the plainest words there are, with one comparison a ten-year-old gets (blades that hit like hammers, a line as long as the drive between two towns).
- Exact small numbers and things you can touch: four springs, twelve hours, a gap the width of a shoelace. Only numbers that are true, or part of an obvious joke.
- Do not answer early. The question from the first sentence stays open until the last or second-to-last sentence.

THE LAST SENTENCE
- It IS the payoff and the video stops on it: the most vivid image, the twist, the knot of the paradox, or the punchline.
- Never a summary, a moral, a lesson, "so next time", "remember", a question to the audience, or a call to like, follow, comment or search. One useful takeaway is allowed only as the tail of the payoff sentence itself.
- A good ending makes a second watch feel worth it.

VOICE
- One narrator telling it to a friend, quick and sure. Past tense for stories, present tense for how things work.
- Words a ten-year-old knows. Never: fascinating, incredible, shocking, surprisingly, little did he know, the truth is, it turns out, believe it or not. No questions in the middle.
- People have no names: a man, a woman, a guard, a baker, the farmer.
- Sentences of 8 to 20 words that run into each other; each reads aloud in one breath.

TRUTH
- Kinds 2, 3, 4 and 5 must be true and checkable. If you are not sure of a fact, do not use it: choose another subject. Never round a number up to make it scarier.
- A legend, a thought experiment or a paradox is told as a story ("a guard once offered a traveller a deal") and never dressed up as news. Never say "this really happened" unless it did.
- No gore. Danger is tension and consequence said in words (stuck, crushed, caught); nobody is shown bleeding, bitten or dying.

VARIETY (no two videos alike)
- Never write the crocodile-and-the-mother paradox, and never retell any other well-known viral short word for word.
- Never reuse a subject, an opening shape, a setting or a hero from the person's recent videos listed in the request.
- Move the world around: a kitchen, a train platform, a desert road, a ship's deck, a snowy cabin, a street market, a workshop, a hospital corridor, a farm, an office at night. Rivers, lakes and animals only when the story needs them.

CHARACTERS
- One hero per video, sometimes one second person or one animal. Every person is clearly an adult, 25 or older. Never a child or a teenager, even when the topic suggests one: make it an adult or an animal.
- When the request gives a hero, use that person. Otherwise invent a NEW one and vary age, gender, skin, build and job from video to video.
- Give the hero ONE fixed look in `characters`: age, hair, skin, build and one plain outfit with colours. Copy it word for word into every imagePrompt the hero is in. The outfit never changes.
- Animals are realistic and highly detailed.

SHOTS
- One scene per sentence, or per half sentence when a sentence holds two pictures. 2.5 to 4.5 seconds each, a new angle every scene.
- The first picture shows the strange thing itself happening, never a person just standing somewhere.
- Alternate: a low wide shot that shows the situation, a close-up that shows the feeling, a detail of the object or animal. When the mechanism is explained use a cutaway: inside the machine, a see-through look inside the body, or a map.
- Every imagePrompt names the camera (low at ground level, eye level, close-up from the chest up, top-down) and ONE blurred object in the very front of the frame.
- A moment that is only imagined or might happen is drawn inside a soft white oval vignette on pale blue; say so in the imagePrompt.
- Expressions are easy to read but real: wide eyes, an open mouth, a raised finger, a hand over the mouth.

MOTION
- The first scene and the payoff get push_in. Calm scenes get a slow pan. Use none for a held beat right after a shock.
- motionPrompt says what moves and how fast.
- Never put words, numbers, ticks or crosses inside a picture: on-screen text is added in the edit.

CHECK BEFORE YOU ANSWER
1. Would a stranger stop on the first seven words?
2. Is the question still open halfway through?
3. Does it end on the payoff with nothing after it?
4. Is every fact true, or clearly a story or a joke?
5. Is it different from every recent video listed in the request?
If any answer is no, rewrite before answering.$w$::text
  )
where slug = 'cutscene';

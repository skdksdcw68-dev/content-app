# Autocast: notes for any AI agent working in this repo

iOS app (SwiftUI, iOS 26) with a Supabase backend (edge functions in `supabase/functions`, SQL in `supabase/migrations`) and a video renderer on Fly. Work on branch `rebuild-engine`. Owner: Abel, 18, builds alone, writes by voice, casual English. Explain in short, plain sentences. Money in USD.

## Rules
- Never put secrets, keys or tokens in the repo, in commits, or in chat. Supabase, Codemagic, Fly, OpenAI and ElevenLabs already hold their own.
- No Mac: the app is compiled and tested only on Codemagic (app id `6ab3c39c03a538c0f89d6a7c`; workflows `ios-tests`, then `ios-testflight`). Never add GitHub Actions. Keep SwiftUI views small: a huge `body` timed the compiler out before (split like `ChatView`).
- The model decides, not code: no regexes or keyword lists to guess what a user means (see `supabase/functions/_shared/route.ts`).
- Show a mockup before building a screen. Match Grok's look for settings; light and dark both follow the phone.
- Keep replies and diffs small. Do what was asked, nothing extra.

## Current state (3 Nov 2026)
- Chat runs on GPT-5.6 (Luna for quick replies, Terra for big questions and web search). It searches the web by itself, knows today's date, and saves notes about the person in `person_memory` (migration 0092).
- App Store submission planned 4 Nov. Do not break the build that is being submitted.

## Next task: Explore tab and Settings sheet
1. Replace the "You" tab with **Explore** (`Tab("Explore", systemImage: "safari")` in `Features/RootView.swift`). Contents, top to bottom: title "Explore" with the profile avatar at the top right, a search field, a "Your library" row (opens the library), "Trending today" cards ("Make this" button), template chips (All, Video, Picture, Voice) and a 2-column template grid: Scary story, Motivation reel, Photo to video, YouTube thumbnail. A template opens a page: preview, short description, a few fields, "Use this template".
2. Put the round avatar at the top right of Home, Chat and Analytics too (remove the gear from Chat). Tapping it opens **Settings as a sheet** (`.sheet`, large detent, corner radius about 34), not a pushed page.
3. Settings sheet matches Grok's: dark `#111` sheet, `#212121` rounded cards (radius 20), separators `#333`, 45 pt rows with outline icons and chevrons, grey 15 pt section labels, a round X at the top left, a floating "Search settings" pill at the bottom that filters the rows. Order: profile card, Subscription banner (Autocast purple, "Usage" button), App (Appearance, Notifications, Picture & video settings), Autocast (Customize Autocast, Memory, Connections, Brand), Data & Information (Usage, Data Controls), Rate the App / Terms of Use / Privacy Policy, Report a Problem, Sign Out, version line. Light mode: sheet `#F2F2F2`, cards white. Reuse the existing screens behind these rows (`ProfileView`, `BrandView`, Usage, Chat settings).
4. Customize Autocast (inside the sheet): Enable switch, preset cards (Custom, Short, Balanced, Detailed, Straight talk) that fill an Instructions box, "Search the web by itself", "No hashtags", "What should Autocast call you?". It saves through the existing `ChatPreferences`.
5. Memory (inside the sheet): "Remember from my chats" switch, "View your memory" opening a page of sections (About you, Your content, Top of mind, Earlier) read from `person_memory`, "Start an incognito chat", "Clear memory". Switch and clear need small server support: ask first.
6. Animations: spring sheet presentation, pages sliding inside the sheet, animated switches. Respect Reduce Motion.
7. Commit and push to `rebuild-engine`, then start `ios-tests` on Codemagic; only after it passes, `ios-testflight`.

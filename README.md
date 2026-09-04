# Autocast -- a short-form content autopilot

An iOS app that plans your short-form video for you. It picks the idea, writes
the hook, the script and the caption, schedules the slot, and -- if you let it
-- posts without asking.

Built entirely from Windows. No Mac, no simulator.

```
Windows (edit)  ->  GitHub (source + CI)  ->  macos-15 runner  ->  TestFlight  ->  iPhone
```

Same pipeline as the `email-app` (Maily) repo: GitHub Actions on a `macos-15`
runner, fastlane for signing and upload, App Store Connect API key for auth.
No Codemagic, no third-party CI, no Mac.

The `.xcodeproj` is **not** committed. [XcodeGen](https://github.com/yonaskolb/XcodeGen)
generates it on the runner from `project.yml`, so the project file never has to
be opened or edited by hand.

## The app

Two tabs, deliberately. An autopilot that needs a five-tab app to supervise is
not an autopilot.

| Tab | What it does |
|---|---|
| **Queue** | Connect screen until an account is linked, then everything it has planned |
| **Settings** | Autopilot rules, pillars, voice, quiet hours, connected account |

Every post moves through a fixed pipeline, and those stages become **filter
chips pinned across the top of the queue** -- tap one to narrow, tap it again
to clear:

| Stage | Meaning |
|---|---|
| Planned | It picked the idea. Nothing is written yet |
| Scripted | Hook, script and caption exist |
| Rendering | A render job is in flight |
| Scheduled | Ready, waiting for its slot (or for you, if approval is on) |
| Posted | Published. Views and likes come back here |
| Failed | Something broke. The row says what |

The thing that makes this an autopilot rather than a queue is the **rationale**
on every post -- one line, in the model's own words, saying why it chose this.
It sits on the row and again at the top of the detail view, above the script.
The question the app answers first is *why am I looking at this*.

### The one consequential setting

**Settings -> Ask before posting.** On, and posts wait for you. Off, and
Autocast publishes on its own. That is the product, and it is also the kind of
switch a person should turn off deliberately, so the footer says plainly which
one is active.

## Current state

The platform connection is **stubbed**. `ContentStore.connect()` waits a beat
and loads pre-planned sample content, so the whole flow -- connect, review,
approve, publish, skip, disconnect -- is real and testable on device today.

Everything a real backend would touch lives behind three methods:

```
ContentStore.connect()      <- OAuth to the platform, create the Supabase session
ContentStore.refresh()      <- page the planner's output out of Supabase
ContentStore.publishNow(_:) <- hand the rendered file to the upload endpoint
ContentStore.posts          <- what the planner has produced
```

No view knows where a post came from, so wiring up the real thing does not
touch the UI.

### Not built yet

- Real TikTok OAuth and the Content Posting API
- The planner itself -- an edge function that decides what to make. Sample
  rationales in `ContentStore+Sample.swift` are hand-written, and they are the
  spec for how the real ones should read
- Rendering. Nothing turns a script into a video yet
- Push notifications. The entitlement and background mode are declared, the
  registration code is not written
- Real metrics. `views` and `likes` are set to zero on publish

## Backend

Supabase project **`dosszkllkassvyprkhrg`** (eu-west-1).

> This project was created as "My Project" and never used -- zero tables, never
> linked. Autocast claimed it because the org is on the free tier, which caps
> **2 active projects**, and both slots were taken (this one and Maily's
> `mhdudbprqbzudpshriyb`). Creating a third fails with a quota error. **Rename
> it to `content-app` in the dashboard** so the name matches what it is.

`supabase/migrations/0001_autopilot.sql` defines the queue, pillars, accounts
and settings, all per-user behind RLS. The planner runs as an edge function
with the service role and bypasses those policies deliberately; the app only
ever holds an anon key plus a user session.

To link and push:

```bash
npx supabase link --project-ref dosszkllkassvyprkhrg
npx supabase db push
```

## CI

| Workflow | Trigger | Needs secrets? |
|---|---|---|
| `.github/workflows/ios-tests.yml` | every push and PR | **No** |
| `.github/workflows/ios-testflight.yml` | manual, Actions tab | Yes, all 7 |

The test workflow generates the project, compiles, and runs the unit tests with
`CODE_SIGNING_ALLOWED=NO`. It needs no Apple credentials at all, so it works
before any signing is set up -- which makes it the fast loop for "does this
compile", the thing that cannot be checked on Windows.

## Signing -- not set up yet

Nothing here is done, and there is a real constraint in the way.

Apple caps **Apple Distribution** certificates at **2 per account**, and both
slots are held by `drobe` and `remi`. The legacy **iOS Distribution** type has
a separate quota, also 2 -- `email-app` took one. **Autocast takes the last
one.** After this, a new app on this account needs an existing certificate
revoked first.

This is why `code_sign_identity` in `fastlane/Fastfile` is `"iPhone Distribution"`
and not `"Apple Distribution"`.

### What has to happen, in order

1. Register App ID `com.abelamare.contentapp` on the Developer Portal, **with
   Push Notifications enabled**. The app declares `aps-environment`, and a
   profile minted before the capability cannot sign a build that declares it --
   email-app had to regenerate its profile for exactly this reason.
2. Create the iOS Distribution certificate and a `content-app AppStore` profile
   against the App Store Connect API.
3. Create the app record in App Store Connect. **Check the name first** --
   "Autocast" is a placeholder and has not been verified against the store.
   See the ITMS-90129 note below.
4. Set the 7 repository secrets.

```bash
openssl genrsa -out key.pem 2048
MSYS_NO_PATHCONV=1 openssl req -new -key key.pem -out req.csr \
  -subj "/CN=Autocast Distribution/O=Abel Amare/C=US"
# POST req.csr to /v1/certificates with certificateType IOS_DISTRIBUTION,
# then POST a profile referencing it, then:
openssl x509 -inform DER -in cert.der -out cert.pem
MSYS_NO_PATHCONV=1 openssl pkcs12 -export -legacy \
  -inkey key.pem -in cert.pem -out identity.p12 -passout pass:YOURPASS
```

> `-legacy` is **required**. OpenSSL 3 defaults to AES-256 + SHA-256 for
> PKCS#12, which macOS `security` cannot import -- it fails with
> `MAC verification failed during PKCS12 import (wrong password?)`, which
> misleadingly blames the password.

### Repository secrets

```bash
R=skdksdcw68-dev/content-app
gh secret set APPLE_TEAM_ID                   -R $R   # TDMFXRJYN7
gh secret set APP_STORE_CONNECT_API_KEY_ID    -R $R
gh secret set APP_STORE_CONNECT_API_ISSUER_ID -R $R
gh secret set KEYCHAIN_PASSWORD               -R $R   # any random string, CI-local only
base64 -w0 AuthKey_XXXXXXXXXX.p8 | gh secret set APP_STORE_CONNECT_API_KEY_CONTENT -R $R
base64 -w0 identity.p12          | gh secret set BUILD_CERTIFICATE_BASE64          -R $R
gh secret set P12_PASSWORD                    -R $R
gh secret set PROVISIONING_PROFILE_BASE64     -R $R
```

## Daily loop

```bash
git push                       # -> compiles and runs tests
gh workflow run ios-testflight.yml -R skdksdcw68-dev/content-app   # -> TestFlight
```

Roughly 10 minutes later the build appears in TestFlight on your phone.

## Changing the bundle ID

It appears in **three** places and all three must match:

| File | Key |
|---|---|
| `project.yml` | `PRODUCT_BUNDLE_IDENTIFIER` |
| `fastlane/Fastfile` | `BUNDLE_ID` |
| `fastlane/Appfile` | `app_identifier` |

## Layout

```
project.yml                     XcodeGen spec -- the "Xcode project"
Gemfile                         fastlane, pinned to 2.237.0
fastlane/                       Fastfile (beta lane), Appfile
.github/workflows/              ios-tests.yml, ios-testflight.yml
Support/ContentApp.entitlements aps-environment
Support/Info.plist              generated by XcodeGen, do not edit
supabase/migrations/            queue, pillars, accounts, settings -- all RLS
Sources/ContentApp/
  ContentAppApp.swift           @main -- starts disconnected
  Models/                       Platform, PostStatus, ContentPillar,
                                ContentPost, SocialAccount, AutopilotSettings
  Stores/
    ContentStore.swift          @Observable @MainActor -- the only writer
    ContentStore+Sample.swift   pre-planned stand-in for a first sync
  Views/
    RootView.swift              the two-tab TabView
    QueueTabView.swift          connect screen or queue
    ConnectAccountView.swift    one button, because there is one thing to do
    PostListView.swift          banner + chips + search + swipe actions
    StatusFilterBar.swift       the chip row pinned under the nav bar
    StatusBadge.swift           the tinted capsule on rows
    PostDetailView.swift        rationale card, script, caption, actions
    SettingsView.swift          autopilot rules, pillars, voice, quiet hours
  Resources/Assets.xcassets     app icon + accent colour
Tests/ContentAppTests/          31 unit tests over ContentStore
```

## Gotchas already handled

Carried over from `email-app`, where each of these cost a debugging session.

- **`ITSAppUsesNonExemptEncryption: false`** -- without it TestFlight blocks
  every build behind a manual export-compliance question.
- **`CFBundleIconName`** -- `GENERATE_INFOPLIST_FILE` is `NO`, so Xcode does
  not inject it. Without it App Store Connect accepts the upload and then
  *silently discards* the build during processing (ITMS-90713), which looks
  exactly like "nothing happened". The Fastfile asserts on it before uploading.
- **ITMS-90129, reserved names** -- Apple rejects a binary whose display name
  collides with an existing app, and its own first-party names are easiest to
  hit. email-app hit this with "Mail". The Fastfile checks the shipped
  Info.plist against a reserved list. **"Autocast" still needs checking against
  the live App Store before the first upload.**
- **A 1024x1024 icon with no alpha channel** -- required, or the upload is
  rejected at validation, well after the build "succeeds". The one committed
  here is a generated placeholder gradient.
- **`UILaunchScreen`** -- without it the app renders letterboxed.
- **A dedicated CI keychain** -- the runner's default login keychain has no
  known password, so codesign raises a permission dialog that hangs forever on
  a headless machine.
- **`security set-key-partition-list`** after import -- without it codesign
  still prompts on first use of the key.
- **Build numbers from `GITHUB_RUN_NUMBER`** -- App Store Connect rejects
  duplicates. Re-running a failed run reuses the number; bump
  `MARKETING_VERSION` instead.
- **`.gitattributes` forces LF** -- edited on Windows, run on macOS; a stray
  CRLF breaks a shell script on the runner.
- **Simulator name picked at runtime** -- names change each Xcode release.
- **`SWIFT_STRICT_CONCURRENCY: complete`** -- an autopilot runs work off the
  main actor by definition. On email-app an unchecked data race corrupted the
  heap and killed the app a minute after every launch, with no useful crash
  log. Treat what it reports as a list of places not yet thought about.

## Known limits

- TestFlight builds expire after **90 days**.
- No SwiftUI previews and no simulator on Windows. The `#Preview` blocks are in
  the source so they work immediately on any Mac.
- The platform connection is stubbed (see **Current state** above).

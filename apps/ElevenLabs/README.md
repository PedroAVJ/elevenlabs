# Dictation Button App

Dictation Button is the macOS and iPhone dictation interface owned by the ElevenLabs plugin. The Mac app is native; the iPhone containing app uses Expo/React Native while retaining native keyboard, Live Activity, Control Center, and dictation-engine integrations. Dictation Button is the public display identity; ElevenLabs remains the target, executable, bundle-family, URL-scheme, storage, telemetry, and provider identity for compatibility. It sends recorded audio directly to [ElevenLabs Scribe](https://elevenlabs.io/speech-to-text), then lets you edit, copy, or paste the transcript.

The Xcode project contains four product targets:

- **`ElevenLabsMac`** — the macOS target, producing the **Dictation Button** app
  with Continuity Microphone support, a global dictation shortcut, and automatic
  paste.
- **`ElevenLabs`** — the Expo/React Native iPhone target with record, edit,
  copy, share, and local transcript history through its native bridge.
- **`ElevenLabsKeyboard`** — the keyboard extension target that shows
  quiet branding while idle and one Send action during dictation, then inserts
  the transcript at the writable cursor focused when delivery completes. It
  does not implement ordinary typing.
- **`ElevenLabsLiveActivity`** — the Lock Screen and Dynamic Island target providing the recording
  launcher, state, pause, and cancel surfaces for iPhone dictation.

The iPhone app, keyboard, and Live Activity use Dictation Button's original icon and
public identity while retaining the established monochrome, red recording, and
ice-blue paused palette. The visual layer is deliberately separate from the
stable internal identifiers and reliability contracts described below.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- An [ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys)
- An iPhone and Apple development signing if you want to run the iPhone app or
  keyboard

## Run the macOS app

1. Open `ios/ElevenLabs.xcodeproj` in Xcode.
2. Select the **ElevenLabsMac** scheme and **My Mac** as the destination.
3. Build and run. The bundle is `ElevenLabs.app`, is displayed as **Dictation Button**, and launches as a
   menu-bar utility, without a Dock icon or Command-Tab entry.
4. Click the menu bar icon, choose **Open Dictation Button**, and save your ElevenLabs
   API key when prompted.
5. Keep your iPhone nearby and locked and its Continuity microphone becomes
   available. There is no stored Mac/iPhone mode: the key you press decides the
   microphone, fresh at every start. If the source you asked for is unavailable,
   Dictation Button says so instead of silently substituting the other one.
6. Four keys drive a dictation, all of them bare taps with no timing windows:

   | Key | Verb |
   | --- | --- |
   | right ⌘ | Mac microphone: start / pause / resume |
   | right ⌥ | iPhone microphone: start / pause / resume |
   | fn | End / hold / release: close toward delivery, park while Draining, or release Held text |
   | Esc | Dismiss |

   The left ⌘ and ⌥ are deliberately untouched, and every chord — including
   ⌘C, ⌘V, and ⌘Tab — keeps its normal behavior. Only a bare press-and-release
   with no other key or modifier is read as dictation.
7. A source key can never deliver text and never destroy it; `fn` only moves
   text toward delivery; `Esc` always dismisses — instantly, with nothing destroyed: the
   dictation leaves the screen and stays recoverable in the waiting-text
   list. Pausing releases the microphone (handing
   your iPhone straight back) and banks the segment, which starts transcribing
   immediately — so the End after a pause is usually instant. The first `fn`
   ends the dictation into Draining. Press `fn` again before it lands to hold
   delivery indefinitely while transcription continues; press `fn` from Held
   to release everything once at the cursor focused then. Nothing reaches your
   cursor before release, and everything banked stays in spoken order.
8. To change microphone mid-thought, pause with the key that is live and resume
   with the other one. While a microphone is hot the other source key only
   nudges: there is no mid-recording handover.
9. The click-through Liquid Glass indicator is one stable capsule for the whole
   open dictation. A Mac start briefly shows a neutral laptop glyph; an iPhone
   start shows a neutral phone glyph with an amber breathing wait-dot until
   capture is live. Both then spring-morph into the real red voice waveform.
   Paused segments transcribe as invisible plumbing: there are no segment cards,
   rails, slivers, counts, or `+N` badges. Pressing `fn` turns the same capsule
   directly into a small typing pill with three hopping dots. The dots claim no
   progress or time remaining; completion is the verified delivery event, not
   an animation finishing. A second `fn` parks landing as one steady amber
   raised hand in the same small output pill; the patter stops, transcription
   continues, and the hand remains until `fn`, a source key, or Esc resolves it.
   It cannot be confused with paused recording's wide frozen waveform. Success,
   errors, model details, and offline notices
   stay in the app instead of becoming floating notifications.
   The two terminal exits happen in place and differ by shape: a delivered
   dictation **pops** (a bloom outward), a dismissed one **folds** (a squash to
   nothing). Neither slides anywhere. Choose **Move HUD…** from the menu-bar
   panel to deliberately grab the capsule and save an exact position anywhere
   on screen; outside that temporary mode it remains fully click-through.
10. A resting dictation shows a **still, dim, sourceless** front card — no
   laptop or phone glyph, because no microphone is live and the next source key
   decides. It never times out; transient caps apply only to connecting,
   releasing, draining, and recovery-held acknowledgments. User-controlled
   Held also never times out.
11. Preloaded sounds: the iPhone wait begins with a low tick, capture-live gets
   one rising ping, pause gets a low held tone, and Escape gets a muted fold
   tone. Closing has its own pair — a quiet typing patter that loops while the
   dots are up, then a soft falling plop as the message lands. Nothing sounds at
   the first `fn` press itself; the patter is the acknowledgment. Parking
   Draining with `fn` stops the patter and plays two dry level knocks, distinct
   from the pause tone; releasing Held simply restarts the patter. Errors are the
   family's only phrase: low and falling. Every cue is synthesized
   deterministically by `scripts/generate-macos-earcons.py`.

You do not have to wait at the keyboard. When an unheld transcript reaches the
delivery boundary, ElevenLabs uses the currently focused writable, non-secure editor —
including a different field or application from where dictation began — and
delivers through the safest supported route for that destination. It does not
require the editor to retain the same Accessibility object identity throughout
dictation. Electron and Chromium applications may rebuild, proxy, or replace
their Accessibility tree and editable node, so node continuity is not a
universal platform invariant.

If no writable editor is focused, ElevenLabs leaves the exact newest completed
dictation on the clipboard and reports the clipboard fallback, regardless of
older recovery entries. The HUD acknowledges that fallback once with a
count-free clipboard glyph, then disappears after two seconds. A failed or
unconfirmed insertion also keeps the exact transcript recoverable and on the
clipboard; its document or clipboard glyph is transient while the dashboard
owns the durable recovery state. Because an unconfirmed side effect may already
have landed, ElevenLabs marks it as possibly delivered and never retries it
automatically. Delayed same-session and recovered entries can be placed
explicitly with **⌥⌘V** at the current writable cursor; possibly delivered
entries require the separate reviewed one-shot authorization. Pressing `Esc`
from a resting dictation dismisses it in the same sense: the banked text never
reaches the cursor, but it stays recoverable in the waiting-text list until you
paste or delete it.

The menu bar item opens a small anchored panel: a live map of your own keyboard
— ANSI, ISO, or JIS, whichever you are typing on — with every key blank except
the four bound ones, which re-glyph as the state changes — including hold on
`fn` while Draining and delivery while Held. It is a mirror, not a
control surface; nothing on the board is clickable. Its footer carries only the
readiness or offline notice, Open Dictation Button, Settings, and Quit, and opening it
never grants Dock or Command-Tab presence. Opening the dashboard
or Settings temporarily gives ElevenLabs normal foreground-app presence in the
Dock and Command-Tab; closing the last of those windows returns it to its quiet
menu-bar-only state. The transient dictation indicator never changes app
presence, and recording plus the global shortcut continue without any window or
menu being open.

Stopping ends the Continuity session before transcription starts, allowing
macOS to dismiss its system-owned capture surface on the iPhone. Each new
dictation reconnects and may briefly show the capsule's connecting pulse before
the capture-live cue confirms that audio is ready. Automatic paste and the
global shortcut require macOS Accessibility permission; without it, the
transcript remains on the clipboard.

While either microphone is actually recording, ElevenLabs smoothly fades the
current output about 12 dB quieter (roughly one quarter of its prior amplitude)
over 400 ms, leaves playback running, then
eases it back over 900 ms on pause, End, Escape, error, sleep, disconnect, or
Quit. It never sends a player a pause command and never starts a second audio
capture session to request ducking. Before every hardware write, ElevenLabs
fsyncs a private recovery receipt containing the original level and the write
in flight. That receipt follows the exact output through a crash or disconnect
and is removed only after the original channel map is restored and read back.
A manual volume change wins immediately; outputs without writable scalar
controls and exact scalar/dB translation keep playing unchanged. This fade is
limited to the live-microphone phase, not the later network request.

You can also build the macOS target from Terminal:

```sh
xcodebuild \
  -project ios/ElevenLabs.xcodeproj \
  -scheme ElevenLabsMac \
  -configuration Debug \
  -derivedDataPath /tmp/ElevenLabsDerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  build
```

That command answers "does it compile". It signs locally, ships the repo's
generic `com.example.ElevenLabsMac` identifier, and leaves the product in
`/tmp` — it does not touch the app in `/Applications`.

To put the current checkout into `/Applications`, run:

```sh
scripts/install-macos.sh
```

macOS keys microphone and Accessibility grants to the bundle identifier and
signature together, and keeps Application Support state per identifier. A build
installed under a different identity is therefore a *different app* to the
system: no permissions, no settings, no enrolled voice profile, and a duplicate
entry in the Accessibility list. The installer avoids that by building under the
identity the installed copy already uses. It reads your team and identifiers
from the untracked `scripts/local-identity.env` described under
[Run the iPhone app and keyboard](#run-the-iphone-app-and-keyboard), defaulting
the macOS identifier to `${APP_BUNDLE_ID}Mac`, and refuses to install when that
disagrees with what is already in `/Applications` rather than silently creating a
second app. It quits ElevenLabs before replacing the bundle — both because a
running bundle cannot be replaced and so the Continuity-microphone session is
released cleanly — then relaunches it.

Settings live behind **⌘,** and cover the full Scribe language catalog,
delivery, sounds, capture-indicator placement, launch at login, the API key,
custom vocabulary, text replacements, per-app rules, transcript history,
structured diagnostics, and a live view of every permission the app depends
on.

**Vocabulary** is the main quality control. Names, jargon, and product spellings
added there are sent with every dictation as ElevenLabs keyterms, biasing
recognition toward them without forcing a substitution. Scribe's current batch
contract permits up to 1,000 keyterms, each fewer than 50 characters and no
more than five words; ElevenLabs also rejects `<`, `>`, `{`, `}`, `[`, `]`,
backslashes, and control characters before upload. Dynamic terms derived from
opt-in caret context take the finite slots before the global vocabulary because
they are more specific to that dictation. ElevenLabs currently adds a 20%
surcharge whenever keyterms are sent, and using more than 100 makes every
request bill for at least 20 seconds. **Replacements** are the blunt instrument
for the cases Scribe gets wrong every time; they always fire locally.

When language is **Auto**, ElevenLabs also reads Scribe's language-confidence
metadata. A result below 50% is kept intact but visibly flagged for review, with
the option to pin a language for later dictations.

Transcripts are kept on this Mac in Application Support, searchable, with
Never/1/7/30/90-day or forever retention and a confirmed one-click purge.
Successful recordings are retained by default for playback and **Process
Again**; that optional library is capped at 1 GiB and refuses a copy that would
leave less than 2 GiB free. Hitting either limit does not discard the transcript.

Every new recording first moves into a separate private, crash-safe recovery
journal. It leaves that journal only after the final transcript and its linked
consumption receipt are durable; a failed request or write leaves the audio
available for retry or explicit discard instead of losing what was said. Every
connectivity-caused failure is also marked for automatic retry: while offline,
the app and menu bar say that recordings are staying local, and the saved queue
wakes once when macOS reports that the connection has
returned. Because an old caret or message draft is not a safe destination, the
recovered transcript waits for explicit manual placement and never auto-sends.
All other service and content failures still require an explicit Retry after
the client's bounded request retries, so a network transition cannot repeat an
unrelated request. Every completed transcript also enters a temporary durable
delivery escrow before
copy or paste, under every History setting. **Never store** removes the
completed History row and creates no successful-audio copy, while the escrow
remains only until output is resolved. Before any external paste the escrow is
marked as possibly delivered, so a crash at the side-effect boundary cannot
cause an unattended duplicate after relaunch. Copy/Paste Last cannot bypass an
unfinished handoff, and every ElevenLabs clipboard writer shares one serialized
transaction so concurrent output cannot substitute a different transcript. A
normal Quit during recording
first finalizes and journals the audio; it also waits for an in-progress file
import to finish secure staging or cancels Quit rather than abandoning a partial
copy. Imports whose duration cannot be established fail closed and are never
uploaded. A validated active WAV left by a process crash is recovered on the
next primary launch. Short recordings are never discarded merely because they
are under an arbitrary duration threshold.

For local development, `ElevenLabsMac` also accepts the API key through the
`ELEVENLABS_API_KEY` environment variable. Never commit an API key.

The single-tester TestFlight beta temporarily receives an operator-provided key
from the local `ELEVENLABS_PRIVATE_BETA_API_KEY` release environment. A release
launch copies it into the ElevenLabs iPhone Keychain before app state is constructed.
The release metadata step fails if that secret is absent. This is a private-beta
bridge, not a public credential-distribution design: rotate the key and replace
the embedded bootstrap with a scoped service credential or authenticated proxy
before broadening tester access.

## Run the iPhone app and keyboard

Install the Expo dependencies and CocoaPods once, then use the normal Expo
development commands:

```sh
npm ci
(cd ios && pod install)
npm run ios
```

`npm start` runs Metro for an already-installed development build. The checked-
in `ios/` directory is intentional because the app includes native extension
targets; it is still the Expo application's normal iOS project.

The checked-in identifiers use the `com.example` namespace. Override these
build settings with identifiers owned by your Apple Developer account; source,
entitlements, and property lists stay in sync automatically:

- `ELEVENLABS_APP_BUNDLE_IDENTIFIER`
- `ELEVENLABS_KEYBOARD_BUNDLE_IDENTIFIER`
- `ELEVENLABS_LIVE_ACTIVITY_BUNDLE_IDENTIFIER`
- `ELEVENLABS_TESTS_BUNDLE_IDENTIFIER`
- `ELEVENLABS_APP_GROUP_IDENTIFIER`

The app and keyboard must use the same App Group override. The defaults remain
safe public examples, so a personal sideload no longer requires source edits.

## Production iPhone release

CI runs `npm run eas:update` after an applicable merge and publishes the EAS
Update without waiting for a binary. After that deployment, run
`npm run eas:plan` from `apps/ElevenLabs` on the operator's Mac. If Expo does
not already have a binary for the deployed fingerprint, run
`npm run eas:build:local`. That command:

1. builds the signed App Store IPA on that Mac with `eas build --local` and
   Expo-managed Apple credentials;
2. verifies that the IPA embeds the deployed fingerprint;
3. sends the local IPA path through EAS Submit to TestFlight;
4. after submission succeeds, registers the IPA and fingerprint with
   `eas upload` for future compatibility checks.

Expo records uploaded local IPAs as uploaded/internal build records, so the
compatibility query intentionally keys on the production fingerprint without
cloud-build profile, distribution, or channel filters. The IPA itself still
uses the App Store production profile and the `production` update channel.
There is no production EAS cloud-build workflow.

The machine needs the Xcode version required by the checked-in project, Node 22
or newer, CocoaPods, and fastlane. Install dependencies at the repository root
and inside `apps/ElevenLabs`. Log in with `eas login` or export `EXPO_TOKEN`,
then provide these values in the local release shell when a native build is
required:

- `ELEVENLABS_PRIVATE_BETA_API_KEY` for the current single-tester bootstrap;
- `ELEVENLABS_SENTRY_DSN` for production observability.

EAS variables with secret visibility cannot be read by a local build, which is
why the private-beta key must exist in the local shell. Signing
material remains in Expo's managed credential service and is never committed.
Build working files stay under ignored `.eas-local-build/` and are removed when
the command finishes. GitHub Actions deploys only the OTA update; it never
builds or submits native code and uses no self-hosted runner.

Production shipping uses the guarded local Expo command, but it does not use
the physical-device installer below. A local install replaces the containing
app and keyboard extension, can displace a TestFlight build, and can interrupt active dictation.
Run it only after the user explicitly requests that exact manual device action in
the current conversation.

For an explicitly authorized physical-device install, put those values plus
your team, signing identity, and device identifier in the ignored
`scripts/local-identity.env`, then run
`scripts/install-iphone.sh --confirm-device-replacement`. The installer builds
directly against the device SDK, packages the checked-in icon PNGs using
`CFBundleIcons`, signs the result, and requires a typed confirmation immediately
before replacing the app. It does not launch or probe the installed app by
default; `--launch-after-install` is a separate action that also requires an
explicit current-conversation request. Each install refreshes only this app
family's cached provisioning profiles and resolves the configured App Group
into temporary entitlement files. That prevents a reinstall from reusing a
nearly expired Personal Team profile and prevents Xcode's profile renewal from
dropping the shared group behind the tracked build-setting placeholder. With
`--no-launch`, the installer retains its safe default and leaves physical launch
acceptance to the user. It does not require an iOS Simulator runtime or modify
tracked identifiers.

Then:

1. Select the same development team for **ElevenLabs** and
   **ElevenLabsKeyboard**, and the Live Activity extension.
2. Run **ElevenLabs** on your iPhone and save your ElevenLabs API key in
   Settings.
3. Open Control Center, touch and hold an empty area, tap **Add a Control**, and
   add **Dictation Button**. iOS owns Control Center placement, so the app
   publishes the control but cannot place it for the user. The same control can
   optionally be assigned to the Action Button.
4. Tap **Dictation Button**. It creates one neutral **Ready** Live Activity
   without taking the microphone or opening the app.
5. Tap that Live Activity whenever you want to dictate. It opens Dictation
   Button, starts listening, and changes the system surfaces to **Recording**.
6. Tap the filled control to pause; it becomes an unfilled play control and
   reads **Paused**. Tap it again to continue the same dictation. The expanded
   Live Activity also exposes Pause and Cancel; compact taps are status-only
   after recording has started.
7. In Dictation Button, open Keyboard Settings. Add the Dictation Button keyboard and enable
   **Allow Full Access**. iOS treats each bundle identity as a new keyboard, so
   permission from a prior identity cannot carry over.
8. Focus the destination field and select the Dictation Button keyboard from the globe
   menu. The keyboard fills with a best-effort realtime transcript. Tap **Send**
   to stop recording: wait for the refined batch result to insert automatically,
   or tap **Send now** to insert the live draft immediately. Either path inserts
   exactly once through whichever writable field currently owns the keyboard.

ElevenLabs does not gate recording on an app-maintained keyboard status. iOS
does not expose a reliable containing-app API for enumerating enabled third-party
keyboards, so the keyboard extension records its own real appearance and Full
Access state in the App Group. First-run onboarding advances from the real
Control Center launcher action and finishes automatically after ElevenLabs has actually
been selected with Full Access; there is no manual Done gate or synthetic text
field.

When opened manually during a session, the app replaces its dashboard with a
minimal handoff surface:
a small state-and-timer line, a strongly voice-reactive white waveform on true
black while recording, and one bare animated manual swipe-back cue. Paused is a
flat pale-blue surface with a blue snowflake and frozen waveform. There are no
cards, setup paragraphs, duplicate controls, or decorative glows in this exit
lane. Routine microphone route reconfiguration stays silent; only a real input
loss interrupts the session. It never automatically opens ChatGPT, Claude, or
another host.

The extension is a delivery surface, not a replacement typing keyboard. It
renders no QWERTY, number, symbol, Start, Pause, Resume, or Cancel controls.
Idle points to the Live Activity. Recording and paused states fill the keyboard-sized
surface with the best current Scribe Realtime text and one Send action. Send
latches the durable Stop command on touch-down before the recording is finalized.
During refinement, **Send now** chooses latency and inserts that live draft;
doing nothing chooses quality and lets the batch result insert automatically.
The intent-backed control keeps stable identity across shared-state polling, so
a parent refresh cannot replace its recognizer during a fast first press. The
globe switcher remains available so Apple's keyboard owns ordinary typing and
correction. Moving the caret or presenting ElevenLabs in another writable field
during transcription does not require a second confirmation: delivery follows
the live document proxy while one atomic source claim prevents realtime and
batch from inserting two copies.

The exact interaction and physical-device acceptance criteria live in
[the iPhone keyboard round-trip specification](docs/ios-keyboard-roundtrip-spec.md).

## Live Activity launcher and active controls

The **Dictation Button** Control Widget is the launcher-preparation surface.
It is a `ControlWidgetToggle` whose app-owned Boolean `SetValueIntent` also
conforms to `AudioRecordingIntent` and `LiveActivityIntent`. From Off, it asks
the existing engine to create or reuse one neutral Live Activity and returns
without opening the containing app or activating audio. The idle card's compact
URL and expanded Start button open `elevenlabs://live-activity/start`; the
foreground app then begins recording and replaces the launcher with the
mandatory recording activity. The WidgetKit kind is stable. Off uses the
generic `mic.fill`; Showing, Recording, and Resuming use `waveform`; Paused uses
an unfilled `play.fill`. The
system owns sizing, Liquid Glass, and
light/dark appearance. A tap changes the system Boolean and its label together
immediately: Showing settles back to Off after the Ready activity appears;
Resuming
is filled while audio activation is pending; Pausing is unfilled while the
current segment closes; and shared state reconciles active transitions.

The idle Live Activity is the direct recording start surface. Expanded Live
Activity buttons and the Control Center toggle route
session-scoped commands to whichever app-owned recorder owns the matching UUID.
Pause closes and deactivates that recorder, finalizes its exact audio file, and
transcribes it as a banked segment. The next paused Control Center or Action
Button invocation atomically assigns durable identities to the old upload and
the new segment, then starts a fresh microphone immediately while the earlier
transcription continues. Compact taps open status without changing an active
session. Completion and cancellation turn the recording activity back into the
Ready launcher; Control Center recreates it after a dismissal.
While active, one serialized visualization heartbeat awaits each ActivityKit
write before sampling the next microphone level, so a continuous stream cannot
invalidate every pending frame.

ActivityKit calls the detached right-side Dynamic Island bubble `minimal`. That
37 x 37 pt surface uses an Apple Music-inspired six-column meter with 1.5 pt
bronze-to-gold hairlines and 1.35 pt gaps. Its height comes from a short envelope
of real microphone energy: silence settles to a visible floor, speech raises
each column, and linear interpolation bridges the 180 ms ActivityKit samples so
the meter appears continuously coupled to the voice. While paused, minimal
replaces the recording meter with a native snowflake; the
expanded surface replaces motion with a static ice-blue frozen waveform and an
explicit Control Center continuation instruction. Neither paused surface
pretends that microphone audio is still arriving.

iPhone capture uses AVFoundation's mixable play-and-record audio session so an
active pause or resume intent can manage the microphone while the containing
app is backgrounded. The initial launcher tap starts in the foreground. Existing
Spotify or Music playback remains active at its
current volume while recording. A2DP keeps the selected AirPods or other media
output eligible while the built-in microphone records, and HFP is intentionally
absent so playback does not fall to the hands-free route. ElevenLabs does not
use the category-wide speaker override because it can displace wireless
headphones; it temporarily selects the speaker only when iOS actually resolves
the output to the built-in receiver.

A Control Center press during transcription or unresolved delivery is absorbed
instead of replacing pending text or starting another recorder. The containing
app and Live Activity render the accumulated session duration plus the current
segment. Once insertion or cancellation reaches a terminal state, the control
returns to Off while the Live Activity becomes the Ready start surface.
During recording, the keyboard may show best-effort Scribe Realtime text while
the durable batch path owns the audio source of truth. Send now remains disabled
until the final stopped realtime source finishes, so it cannot omit a newer
paused or resumed segment. The live draft and batch completion arbitrate under
the same shared-state lock and exactly one may own insertion.

An older reference-derived host detector and fixed URL catalog remain as
dormant compatibility evidence, pinned by
`docs/protected-switchback.sha256`. Automatic switchback was explicitly retired
on 2026-08-24 because it could not provide one consistent expectation. Active
UI and app code are structurally guarded from reconnecting that path.

## Privacy

- API keys are stored in the platform Keychain. The keyboard extension never
  receives the key.
- Audio is sent directly to ElevenLabs. Quality-first transcription uses
  `POST https://api.elevenlabs.io/v1/speech-to-text` with `scribe_v2`; active
  keyboard sessions also stream mono PCM to
  `wss://api.elevenlabs.io/v1/speech-to-text/realtime` with
  `scribe_v2_realtime`. The dual pass consumes both realtime and batch usage.
  Batch upload requests do not follow HTTP redirects, so the API key and speech
  body cannot be forwarded to another origin by a 3xx response.
- On macOS, audio is staged in a private recovery journal before upload.
  Interrupted, failed, or not-yet-durable work remains locally recoverable.
  After the recovery transaction closes, successful audio is retained by
  default in a separate History library for playback and reprocessing. History
  copies use speech-efficient AAC/M4A rather than duplicating the recorder's
  large recovery WAV files; older WAV History copies are migrated in place.
  The library is capped at 1 GiB, preserves a 2 GiB free-space reserve, follows
  the History retention setting, and can be disabled or purged. **Never store**
  keeps neither completed History nor successful-audio copies. On iPhone,
  manual in-app recordings are retained after an API failure so Retry can reuse
  them. Successful iPhone History entries retain a complete-file-protected
  on-device copy for playback and diagnosis while space allows, capped at 250
  MiB across the library. Deleting or expiring a History entry deletes its
  retained audio. The audio itself never enters Sentry; a deliberate **Report
  garbled** action sends only coarse signal, duration, language-confidence, and
  microphone-mode buckets. Shortcut-driven background recordings are deleted
  after their private History copy is durable, or after cancellation or failure.
  A hard suspension can interrupt
  normal upload-copy cleanup, so the next iPhone app launch removes only exact
  private `ElevenLabs-upload-<UUID>.multipart` artifacts left by that process.
- macOS transcript History stays on-device, has a 500-entry ordinary cap, and
  supports Never/1/7/30/90-day or forever retention. Recovery-linked proof may
  temporarily exceed that cap rather than be destroyed. Unresolved output
  remains in a private delivery escrow under every retention setting; an entry
  marked possibly delivered is never retried implicitly. A row cannot be edited
  or reprocessed while its source-audio or delivery transaction is open. The
  iPhone history remains capped at 50.
- Optional recognition context reduces a small caret-local window, selection,
  application name, and window title to spelling keyterms before upload. It is
  off by default, never reads secure fields, and does not store the captured
  text in diagnostics. Independently of that setting, cursor-aware local
  formatting may read at most 256 characters before the caret in process memory
  to choose spacing and capitalization. That local text is never uploaded or
  stored, and secure fields remain excluded.
- Full Access lets the keyboard share dictation state with the containing app.
  ElevenLabs does not collect general keystrokes.
- Remote observability is **off unless you configure a Sentry DSN**. When it is
  configured, transcription and insertion events contain privacy-safe counts,
  internal correlation IDs, and allowlisted state—not dictated text or host
  cursor content. See [Observability](#observability).

Review [ElevenLabs' privacy policy](https://elevenlabs.io/privacy-policy) before
sending sensitive audio.

## Observability

ElevenLabs can report its own health to Sentry — errors plus structured logs —
so a crash or a run of failing transcriptions is visible without reading local
diagnostics on the device. Transcription and insertion telemetry includes
character counts, internal correlation identifiers, coarse host identity, and
the exact state boundary that failed. Dictated text and document context remain
on device.

Set the DSN through the `ELEVENLABS_SENTRY_DSN` build setting, which feeds the
`SentryDSN` Info.plist key on both apps. `SENTRY_DSN` in the environment
overrides it for local runs. With no valid HTTPS DSN configured — the default —
the SDK never starts and nothing leaves the device.

Both installers read `ELEVENLABS_SENTRY_DSN` from the untracked
`scripts/local-identity.env` and pass it to the build, so an installed copy
reports without the DSN ever entering a tracked file. Each one prints whether
the build it just installed has observability on, and fails rather than install
a build a configured DSN did not reach — a silently uninstrumented app is
indistinguishable from a healthy one until nothing arrives in Sentry.

Reported events:

| Event | Meaning |
| --- | --- |
| `elevenlabs.started` | The app launched; carries `macos` or `ios`. |
| `elevenlabs.previous_session` | What the local health marker proved about the previous run, including an unclean exit. |
| `elevenlabs.clean_termination` | The app reached its normal shutdown path. |
| `elevenlabs.audio_session_transition` | iPhone audio configuration moved through preconfiguration, configured, or activated; carries only public category/options state and coarse route classes. |
| `elevenlabs.audio_capture_started` | iPhone capture started; carries the surface, bounded attempt count, application state, category/options state, speaker-fallback state, and coarse input/output route classes. |
| `elevenlabs.audio_capture_failed` | iPhone capture exhausted or failed its start path; carries the same state plus a stable stage/reason and a whitelisted numeric system code. It also creates a grouped Sentry issue. |
| `elevenlabs.audio_route_changed` | iOS changed the active route during capture; carries the stable route-change reason and previous/current coarse route classes without device names or identifiers. |
| `elevenlabs.audio_speaker_fallback_failed` | The receiver-only speaker fallback failed; carries the current public session snapshot and a whitelisted numeric system category. |
| `elevenlabs.audio_session_release` | iPhone relinquished media focus, or a bounded release retry failed; carries the stable exit reason, attempt, public session snapshot, prior output class, and a whitelisted numeric system category. |
| `elevenlabs.other_audio_recovery_observation` | After a successful release that began over other audio, samples iOS's public other-audio-playing hint at 250 ms and, if needed, 1 second. This observes reactivation but cannot identify a player or prove audible output. |
| `elevenlabs.audio_diagnostic_retained` | A successful History entry retained on-device audio; carries exact capture sample count, audible fraction, average/peak level, clipping fraction, microphone modes, duration, language confidence, and segment count. |
| `elevenlabs.audio_diagnostic_archive_failed` | The private diagnostic copy could not be made; carries only a stable storage reason. |
| `elevenlabs.audio_diagnostic_reported_garbled` | The user reported a retained recording as garbled; creates a grouped issue using the same exact capture measurements. |
| `elevenlabs.realtime_transcription` | The optional live lane started, produced its first draft, finished, or failed; carries session ID, bounded reason, latency, and character count without text. |
| `elevenlabs.transcription_completed` | ElevenLabs returned a segment; carries its character count, session and part IDs, requested/detected language, confidence, duration, and execution surface. |
| `elevenlabs.dictation_finished` | A dictation completed; carries session ID, outcome, duration, and length. |
| `elevenlabs.keyboard_delivery` | The keyboard attempted host insertion; carries character count, realtime-or-batch source, session/attempt IDs, host bundle, document IDs, callback result, latency, and `attempting`, `confirmed`, or `unconfirmed`. |
| `elevenlabs.transcription_failed` | A transcription failed; carries the typed category, HTTP status, complete error message, session/part IDs, duration, exact capture measurements, microphone modes, and execution surface. |

Delivery telemetry sends correlation IDs, coarse host identity, delivery source,
length, and terminal outcome. Transcript text, document-proxy context, raw audio,
and the ElevenLabs API key are not remote telemetry fields. Automatic network
tracking, breadcrumbs, sessions, and performance traces remain off; only the
explicit events above are sent.

All emission goes through `ElevenLabs/Observability.swift`, which is shared by
the macOS and iPhone apps and is a no-op until a DSN is configured. The keyboard
persists its local insertion trace to the App Group; the containing app forwards
only its sanitized projection through Sentry the next time it becomes active.
The Live Activity does not run a separate SDK.

## Development status

The macOS target builds with local ad-hoc signing. Its floating indicator is one
click-through Liquid Glass capsule with a stable identity for the entire open
dictation. Source glyphs bloom at center, listening uses the real voice
waveform, rest freezes that waveform in gray, and `fn` morphs directly to one
typing-dots face while every banked segment remains invisible plumbing. A
second `fn` before landing parks delivery indefinitely as a steady amber raised
hand while transcription continues; `fn` releases it once at the current
cursor, either source reopens it, and Escape moves it to recovery. Only verified
delivery pops outward; Escape folds inward. A separate recovery hold appears
only as one count-free clipboard-or-document glyph for two seconds.
Recovered and possibly delivered text stays in the dashboard and is never
replayed into the HUD on launch. The capsule has no controls and never presents
results, offline notices, or errors. Draining is capped at 90 seconds so a
stalled request cannot pin it onscreen; user-controlled Held has no cap. The
dashboard and menu bar remain
authoritative. Its persisted custom position is editable only through the
menu-bar panel's deliberate move mode, so normal HUD use stays click-through.
The Mac source courtesy beat is capped at 0.5 seconds, an iPhone
wait at 20 seconds, and releasing at 15 seconds. The iPhone wait normally stays visible until
the microphone proves it is delivering a steady sample stream, so
file recording does not begin inside the Continuity wake-up gap; if macOS
refuses the monitoring tap that proves liveness, the connection fails loudly
instead of recording unguarded.
Interrupted startup is retried in place, a stream that dies mid-dictation
salvages its finalized partial file, and recording startup, WAV finalization,
network requests, retry concurrency, and long-session limits are bounded.

The indicator can be anchored at any screen edge without becoming a second
control surface. Each dictation verb has its own bare key: right ⌘ and right ⌥
start, pause, and resume on the Mac and iPhone microphones, `fn` ends, parks
Draining, or releases Held delivery, and `Esc` dismisses. Changing microphone mid-thought is pause then
resume on the other key, which finalizes the current segment and releases its
hardware before the next one starts. One Escape dismisses connecting or
recording immediately, without destroying anything. Its preloaded sound family
is documented in [the HUD specification](docs/macos-dictation-hud.md); errors
are the family's only phrase: low and falling. All normal builds that own ElevenLabs'
shared local stores use one product-wide process lease,
independent of bundle identifier; a secondary launch exits without initializing
app data. While the microphone is recording, ElevenLabs prevents idle display
The current macOS capability set and the features deliberately excluded from
the product are recorded in [the product-parity ledger](docs/macos-feature-parity.md).
Compilation, focused logic tests, and isolated UI inspection do not prove the
system-owned Continuity UI or a real destination application's accessibility
behavior; follow
[the direct-device acceptance run](docs/macos-remaining-work.md) before calling
the complete Mac experience physically verified.

For iPhone:

- The iOS 18 Control Widget creates or restores one idle Live Activity without
  taking the microphone. The same control can be assigned to the Action Button.
  Tapping the Ready activity opens Dictation Button and starts recording. Its
  filled Recording state pauses on the next control tap; the unfilled
  play/Paused state continues the same segmented dictation.
- Idle compact Live Activity taps start dictation; active compact taps are
  status-only. Expanded recording UI exposes
  Pause and Cancel; expanded paused UI exposes Cancel and a Control Center
  continuation instruction. Paused minimal is a native snowflake and expanded
  pause uses a static ice-blue frozen waveform. Success and cancellation return
  the activity to the Ready launcher. The regular compact
  surface keeps a live elapsed timer and the active minimal right bubble uses a
  six-bar Apple Music-inspired meter driven by microphone energy; the Lock
  Screen and expanded island repeat only the same state proof, timer, waveform,
  and appropriate controls.
- The keyboard is send-only: idle points to the Live Activity, recording or paused
  exposes one Send action, and transitional states expose progress. Start,
  Pause, Resume, and Cancel are absent from the keyboard.
- The containing app has first-run launcher and keyboard onboarding and a
  strongly voice-reactive recording waveform. A headless Control Center action
  marks real launcher practice without presenting a scene; the subsequent Live
  Activity tap deliberately opens Dictation Button to start.
- Shared-session, audio-stage, insertion, and recovery diagnostics remain in the
  App Group. Dormant host-detection compatibility code stays hash-pinned but is
  structurally disconnected from active UI and app flow.
- The legacy build 2 exposed grouped `record()` rejections after five
  reused-recorder attempts; later invocations with fresh recorder instances
  completed on `MicrophoneBuiltIn`. The recorder is recreated within the same
  gesture using a bounded six-second settling budget. Each retry reasserts the
  built-in input route while preserving the already-granted session; it never
  deactivates and then tries to reacquire background recording permission.
  Current capture uses a
  mixable `.playAndRecord` session with A2DP output eligibility and no ducking,
  so selected AirPods remain the media output and playback volume stays stable.
  HFP remains excluded so the headset cannot claim the input or degrade media to
  hands-free quality. Terminal capture paths stop and release the last I/O owner
  before a bounded, observed `.notifyOthersOnDeactivation` handoff. A Live
  Activity pause finalizes and banks the exact segment; continuing from Control
  Center starts a fresh recorder file in the same logical dictation, so paused
  time adds no audio bytes. Microphone startup uses AVAudioEngine's throwing
  boundary. The resulting `AVAudioSession.ErrorCode` is translated once into
  an exhaustive product error: background policy refusals continue in the
  foreground, `sessionNotActive` gets one 250 ms route repair, and every other
  failure surfaces immediately. Each rejected attempt removes its header-only
  file before any continuation. The signed
  installer also supports installation without foreground activation while
  still verifying that iOS accepts the signed executable, and capture failures report under the ElevenLabs Sentry
  release and event namespace. Broader interaction checks remain separate
  physical-device acceptance steps.

The headless Control Center launcher, idle Live Activity start,
pause/continuation, expanded Pause/Cancel, and
keyboard Send flow require the direct physical-device matrix in
`docs/ios-keyboard-roundtrip-spec.md`. A compile, signed install, successful
intent result, or processed TestFlight build does not establish that acceptance.

## Reference IPA tooling

The repository owns the helper used to download the latest Wispr Flow and
Superwhisper IPAs for local product research:

```bash
ipatool auth login
./scripts/download-reference-ipas.sh
```

The helper relies on `ipatool`, `jq`, `unzip`, and `shasum`. It uses ipatool's
saved App Store session and never reads or forwards an Apple ID password. IPAs
are written with mode 600 outside the repository, under
`~/Library/Application Support/ElevenLabs/ReferenceIPAs` by default. Override
that location with `ELEVENLABS_REFERENCE_IPA_DIR` when needed.

## License

ElevenLabs is available under the [MIT License](LICENSE).

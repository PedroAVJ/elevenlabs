# Dictation Button app

Dictation Button is the public dictation interface owned by the parent ElevenLabs plugin. ElevenLabs remains its compatibility-sensitive code, target, bundle, URL-scheme, storage, telemetry, and provider identity. It contains the native macOS app, an Expo/React Native iPhone containing app, and native keyboard and Live Activity extensions.

## Targets

- `ElevenLabsMac`: macOS SwiftUI app; current development focus.
- `ElevenLabs`: Expo/React Native iPhone containing app with a narrow native bridge to the existing dictation engine.
- `ElevenLabsKeyboard`: iPhone custom keyboard extension.
- `ElevenLabsTests`: shared and iPhone-focused tests.

## Working rules

- Preserve the ElevenLabs executable/product name, bundle identifiers, signing identity, URL scheme, Application Support paths, Keychain identifiers, and widget kind. They protect installed permissions and durable user state even though the public display name is Dictation Button. Debug configurations remain generic for local development; the Release configurations intentionally carry the production identifiers and Apple team required by EAS Build.
- The parent repository owns separate platform-correct Dictation Button launcher assets for macOS/plugin and iOS. Use its `npm run sync:native-icons` task to update the complete Xcode icon catalog. The resting menu-bar mark is the generic `waveform` symbol; keep active HUD, keyboard, shortcut, menu-bar status, and Live Activity symbols state-specific.
- Never commit or print the ElevenLabs API key. Runtime code reads it from the per-app Keychain or `ELEVENLABS_API_KEY`.
- Remote telemetry goes through `ElevenLabs/Observability.swift`. Instrument transcription and cross-process keyboard delivery with privacy-safe character counts, session/part/attempt identifiers, host bundle identifier, delivery source, and exact terminal outcome. Dictated text and document context stay on device. The keyboard records its local trace in the App Group and the containing app forwards only the sanitized fields through the configured Sentry client on its next activation.
- Fully release the Continuity-microphone session after every dictation, before transcription. Returning control of the iPhone takes priority over warm-start latency.
- Keep generated builds, DerivedData, user Xcode state, and packaged ZIPs out of Git.
- Keep the iPhone release on Expo's native-fingerprint contract, with OTA and native delivery as separate stages. CI publishes every production EAS Update without first requiring a compatible binary; the fingerprint runtime prevents incompatible installed binaries from receiving it. After deployment, `scripts/build-ios-local.sh --check` determines whether the deployed fingerprint needs a new binary. Only then may the user run the same script to create exactly one signed IPA with `eas build --local`, submit it through EAS Submit, and register it with `eas upload`. CI must never compile or submit native code, and no self-hosted runner or EAS cloud-build trigger belongs in this path.
- Production native delivery is run manually from the operator's Mac; it never authorizes a local iPhone install or any change to another build or submission. Do not cancel, retry, replace, build, sign, install, reinstall, launch, terminate, or probe the app or its extensions on the user's iPhone unless the user explicitly requests that exact manual device action in the current conversation. Leave physical-device acceptance to the user when it has not been explicitly delegated.
- `scripts/install-iphone.sh` is an exceptional local-development tool, not a release path. Its `--confirm-device-replacement` flag and terminal confirmation may be used only after the explicit request above; never infer that permission from a request to ship, test, verify, or fix the app.
- Prefer focused Swift type-checks and target builds. Do not modify signing teams or publish through the App Store unless explicitly requested.
- Never synthesize or inject keyboard input to test Dictation Button, including with
  `CGEvent`, AppleScript/System Events, Computer Use, or virtual-key tools.
  Modifier-only shortcut acceptance is user-only physical testing; do not
  interfere with the user's active apps or typing.

### Reference-backed behavior

- Before reinventing complex or stateful product behavior, inspect its current
  observable behavior and any legally reusable licensed implementations and
  tests. Record the state transitions, invariants, cancellation and failure
  paths, compatibility assumptions, and any gaps that remain hypotheses.
- Adapt the proven pattern to ElevenLabs's architecture. Never transplant
  private or unlicensed code; reuse licensed code only after checking that its
  license, dependencies, lifecycle, privacy, and failure semantics fit, and
  otherwise implement an independent adaptation.
- Verify the complete sequence on every intended target surface. Builds,
  isolated callbacks, and copied tests alone are not acceptance.

### Protected iPhone manual-flow contract

- The explicit product decision from 2026-08-24 is that manual home-bar swipe
  is the only return expectation. Do not promise or initiate automatic return
  to ChatGPT, Claude, or any other host.
- **Dictation Button** in Control Center, or the same control assigned to
  the Action Button, arms the persistent idle Live Activity. Its stable WidgetKit kind
  is `com.pedro.ElevenLabs.control.dictation`. Preserve it so an installed
  control refreshes in place. It is a `ControlWidgetToggle` titled Dictation:
  Off uses the generic `mic.fill`, Showing and Recording use `waveform`, and
  Paused is unfilled with `play.fill`. WidgetKit's optimistic
  Boolean and the shared recorder state use
  the same Recording, Pausing, Paused, and Resuming presentation so
  the fill and value text never advance independently.
- The control must use the app-owned `ToggleDictationControlIntent` as a
  Boolean `SetValueIntent` that also conforms to `AudioRecordingIntent` and
  `LiveActivityIntent`, with target membership in both the containing app and
  widget extension. Preparing the launcher remains headless. On iOS 26 the intent
  supports background plus dynamic foreground execution; iOS 18-25 use the
  app-target `ForegroundContinuableIntent` compatibility path. Only a typed
  audio-session policy refusal may request foreground continuation, after the
  empty start is rolled back; retrying that refusal in the background is
  forbidden. The app-target `perform()` awaits the existing
  `DictationEngine`: true shows the launcher from Off or resumes from Paused;
  false pauses only from Recording. The idle card and its expanded Start button
  use `elevenlabs://live-activity/start` to open Dictation Button and start the
  microphone in the foreground. Recording still establishes its mandatory Live
  Activity before activating audio.
- An idle compact Live Activity tap starts dictation; compact taps during an
  active session remain status-only. The expanded idle activity has a labeled
  Start action, and the expanded recording activity
  exposes Pause and Cancel. Pause closes and deactivates the current microphone
  segment, then banks its transcript in the shared session. The paused minimal
  presentation is a snowflake; the expanded paused presentation is a static
  ice-blue waveform with Cancel and an instruction to continue from Control
  Center. The next Control Center or Action Button toggle starts a fresh audio
  segment in that same dictation after the paused segment is safely banked.
  Completion and cancellation turn the recording activity back into the idle
  launcher. Control Center can recreate it after a user or system dismissal.
- The custom keyboard is delivery-only. It must never expose Start, Pause,
  Resume, or Cancel. It may render the best current realtime draft; Send stops
  recording, and Send now may claim that draft while the quality-first batch
  request continues. Exactly one of realtime or batch may own insertion.
- The prior host-detection and fixed-catalog switchback implementation remains
  dormant historical compatibility evidence. `docs/protected-switchback.sha256`
  pins its untouched core files, while structural tests prove that active app
  and keyboard UI do not call it. Never reconnect it without a new explicit
  product decision, fresh reference inspection, and physical-device proof.
- Builds, simulators, intent return values, and processed TestFlight builds do
  not prove Control Center, Notification Center, Dynamic Island, keyboard
  insertion, or microphone behavior. Run the physical matrix in
  `docs/ios-keyboard-roundtrip-spec.md` before calling that interaction accepted.

## macOS build

To check that the project compiles:

```sh
xcodebuild \
  -project ios/ElevenLabs.xcodeproj \
  -scheme ElevenLabsMac \
  -configuration Debug \
  -derivedDataPath .codex-artifacts/native-build/DerivedData \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  build
```

This proves compilation only. It builds the repo's generic
`com.example.ElevenLabsMac` under local ad-hoc signing and leaves the product in
the clone-local build directory, so the app in `/Applications` still runs the previous code. Never report
a change as runnable on the strength of this command.

## macOS install

To make a change usable in the installed app, run `scripts/install-macos.sh`.

macOS keys microphone and Accessibility grants to the bundle identifier and
signature together, and keeps Application Support state — including the enrolled
voice profile — per identifier. Installing under any other identity produces a
second app with no permissions and no state rather than an upgrade, so the
installer builds under the identity already in `/Applications`, reading the
untracked `scripts/local-identity.env` and refusing to run on a mismatch. It
quits ElevenLabs before replacing the bundle and relaunches it afterward.

Do not pass one-off `PRODUCT_BUNDLE_IDENTIFIER` or `DEVELOPMENT_TEAM` overrides
by hand to install; that is how a duplicate permission-less app gets created.
Extend the script instead.

See `README.md` for product behavior, installation, privacy, and current verification status.

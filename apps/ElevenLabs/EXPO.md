# Expo iOS release contract

The iPhone containing app remains a normal Expo/React Native app. `index.js`
loads `App.js`, Metro creates the JavaScript bundle, Expo SDK modules provide
the runtime, and `expo-updates` installs compatible over-the-air updates.

The committed `ios/` project is intentional because this product also owns the
native keyboard and Live Activity extensions. The main `ElevenLabs` target
hosts Expo and exposes the existing recording, Keychain, history, Control
Center, and Live Activity behavior through `ElevenLabsNative`. The macOS target
also remains native.

## Binary or JavaScript update

Production uses Expo's fingerprint runtime policy and the `production` update
channel. CI publishes the EAS Update after every applicable merge without
waiting for a compatible binary. Expo gives that update the source tree's
fingerprint runtime, so only a binary with the same runtime can load it. If the
fingerprint is unchanged, existing compatible binaries receive the update. If
it changed, the update remains published for the new runtime while the signed
binary is compiled separately on the operator's Mac.

Typical JavaScript-only changes in `App.js` or `index.js` use EAS Update. A
change to native Swift or Objective-C, extensions, entitlements, Podfile,
native dependency, or native app configuration requires a binary. Changes
confined to the macOS target, CLI, tests, or documentation are excluded from
the iPhone fingerprint and do not consume a native build.

OTA updates do not consume or change an Apple build number. `eas.json` keeps
`cli.appVersionSource` set to `remote` and production `autoIncrement` enabled,
so only a new binary advances the App Store build number.

## Production release

OTA deployment and native delivery are intentionally separate:

1. `.github/workflows/elevenlabs-testflight.yml` validates the final `main`
   source and runs `npm run eas:update`. That command publishes the production
   EAS Update unconditionally; it never queries, creates, cancels, or submits a
   build.
2. After that deployment, run `npm run eas:plan` on the operator's Mac. It
   computes the same production fingerprint and checks Expo's finished binary
   inventory without changing it.
3. If a compatible binary already exists, no native work is needed. Otherwise,
   run `npm run eas:build:local` on that Mac. It runs the native Swift suite
   serially, creates one signed IPA with `eas build --local`, verifies the
   embedded fingerprint, and sends the local path to EAS Submit for TestFlight.
4. After submission succeeds, the command registers that IPA and fingerprint
   with `eas upload` for future compatibility checks.

`npm run eas:release` remains an alias for the OTA-only update command. It does
not compile native code. The local native command never publishes an OTA update
and never alters another build or submission.

Expo records uploaded local IPAs as uploaded/internal build records. The
compatibility query therefore uses the production fingerprint without the
cloud-only profile, distribution, or channel filters. The signed IPA itself
still uses the App Store production profile and production update channel.

GitHub Actions owns only validation and EAS Update publication. It has no
self-hosted runner and no native build, submit, or upload step. There is no EAS
cloud-build workflow. The remaining
`.eas/workflows/submit-existing-build.yml` only resubmits a previously recorded
EAS build ID.

## Mac and credentials

Install the Xcode version required by the checked-in project, Node 22 or newer,
CocoaPods, and fastlane. Install repository dependencies with `npm ci` at the
repository root and inside `apps/ElevenLabs`. GitHub Actions uses the
repository's `EXPO_TOKEN` only for EAS Update. For the post-deployment check and
native build, log in locally with `eas login` or provide `EXPO_TOKEN` in the
local shell.

Before a native production build, provide these values in the local shell:

- `ELEVENLABS_PRIVATE_BETA_API_KEY` for the current single-tester bootstrap;
- `ELEVENLABS_SENTRY_DSN` for production observability.

EAS variables with secret visibility cannot be downloaded into a local build,
so the private-beta key must be present locally. Apple signing material stays
in Expo's credential service and is downloaded only for the local archive. No
credential is committed. Build working files live under ignored
`.eas-local-build/` and are deleted when the command finishes.

The local build command also disables Expo's automatic capability mutation.
The checked-in Xcode targets already declare the containing app, keyboard, Live
Activity, and shared App Group capabilities, so the archive preserves those
capabilities instead of trying to remove an extension's App Group in Apple's
portal.

## Local checks

Run serially on this Mac:

```sh
npm ci
npm run export:ios
npm run fingerprint:ios
npm test
npm run eas:validate
```

For local iPhone development, use `npm start` with a development build or
`npm run ios`. For an explicitly authorized physical-device install, use
`scripts/install-iphone.sh`; that installer is separate from production release.

The production App Store identity remains `com.pedro.ElevenLabs`, with EAS
project ID `33e2bdea-25eb-45b1-bd39-01c332a37820` and App Store Connect app ID
`6804516163`.

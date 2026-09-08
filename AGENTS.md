# Repository guidance

- This repository is the canonical source for the `elevenlabs` plugin and its two owned interfaces: the agent-facing CLI/skill and the native Dictation Button macOS/iPhone app under `apps/ElevenLabs`.
- Follow `apps/ElevenLabs/AGENTS.md` for native-app work. Dictation Button is the public app identity; ElevenLabs remains the compatibility-sensitive target, executable, bundle-family, URL-scheme, storage, telemetry, and provider identity. Keep those internal identifiers stable unless a migration is explicitly designed and physically verified.
- `assets/elevenlabs-icon.svg` and `assets/dictation-button-ios-icon.svg` are the deterministic sources for the original Dictation Button macOS/plugin and opaque full-bleed iOS artwork. Run `npm run sync:native-icons` after changing either, then keep every Xcode app-icon size synchronized. Public idle surfaces use generic waveform or microphone symbols; recording, pause, error, keyboard, HUD, and Live Activity symbols remain state-specific.
- The CLI and native app currently use separate Keychain records. Do not unify or rename them as part of an unrelated change.
- Keep the Codex and Claude manifests synchronized when both are present. The Claude plugin is intentionally absent for Codex-only plugins.
- Marketplace catalogs reference this repository; do not duplicate runtime behavior back into a marketplace repository.
- Keep credentials and personal data out of Git. Preserve stable command names, service labels, cache paths, and credential identifiers across releases.
- Bump the plugin version for released behavior changes and run `npm test` before publishing. Keep Swift validation bounded to one job on this Mac.
- The iPhone containing app is Expo/React Native and uses `expo-updates`. The keyboard and Live Activity remain native extension targets, and the macOS app remains native. JavaScript-only CLI/plugin changes do not affect the mobile app.
- Keep OTA and native delivery independent. GitHub Actions may validate and publish `eas update` to the production channel after a merge; never gate that update on an existing binary. After deployment, the user may run `apps/ElevenLabs/scripts/build-ios-local.sh --check` on the operator's Mac. Only a missing compatible production fingerprint permits that same local script to create one signed IPA with `eas build --local`, submit the local path with EAS Submit, and register it with `eas upload`. CI must never compile or submit a native binary, no self-hosted runner is part of this release, and no release task may cancel, retry, replace, or otherwise alter a build or submission it did not create.
- Keep EAS build numbers remote with `autoIncrement: true`. Bump the user-facing app version deliberately for a release cycle; do not spend a build merely to edit or synchronize a local build number.

## Design workspaces

Keep account-specific design mappings and exports in ignored local configuration.
Resolve the user's chosen design workspace before accessing or changing it.
Do not commit private design conversations, screenshots, or account identifiers.

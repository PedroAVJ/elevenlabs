# ElevenLabs

Use ElevenLabs through agent-facing audio tools or the native Dictation Button app for macOS and iPhone.

This repository owns two interfaces to the same program:

- **Agent tools** — the `elevenlabs` CLI and skill for Scribe file transcription with language hints, diarization, keyterms, multiple output formats, and a shared local result cache.
- **Dictation app** — the [Dictation Button app](apps/ElevenLabs/README.md), including a native macOS menu-bar app and an Expo iPhone app whose native Control Center button and Live Activity control dictation while its custom keyboard delivers Scribe transcripts.

Raw CLI results are cached locally (`~/.cache/elevenlabs-transcripts/`, keyed by audio hash + options), so repeat transcriptions of the same file are free; pass `--no-cache` to bypass.

This project is unofficial and is not affiliated with ElevenLabs.

## Requirements

- Python 3
- `requests`
- An ElevenLabs API key stored in macOS Keychain

Import an existing shell key once, without printing it:

```bash
elevenlabs auth import-environment --json
elevenlabs auth status --json
```

The Keychain service is `com.pedroavj.apps.elevenlabs`, account `api-key`.
`ELEVENLABS_API_KEY` remains an explicit per-process override for development
and CI; background consumers do not depend on shell startup files.

## Start

```bash
elevenlabs transcribe meeting.mp4 --language es --diarize --response-format diarized_text --out transcript.txt
```

`bin/elevenlabs` is the plugin's entry point and belongs on PATH. Other
plugins and repos call transcription through that command rather than
reaching into this plugin's install directory.

Use the `elevenlabs` skill for the documented Scribe options and safety rules.

## Dictation app

The Expo project lives at `apps/ElevenLabs`; its committed Xcode project lives under `ios/` so the native keyboard, Live Activity, and macOS targets stay in the same product. Dictation Button is the public app identity. ElevenLabs remains the target, executable, bundle-family, URL-scheme, storage, telemetry, and speech-provider identity so installed permissions and durable state continue working. Its launcher artwork is an original voice-to-text mark with separate macOS/plugin and opaque full-bleed iOS sources. The resting menu-bar mark is a generic waveform.

```bash
npm run sync:native-icons
npm run test:native
```

To install the signed macOS or iPhone build, follow the native app's [installation instructions](apps/ElevenLabs/README.md). Installing the Codex or Claude plugin does not automatically install an application bundle.

## Public source and independent deployments

First-party code and original Dictation Button artwork are MIT licensed; keep
`apps/ElevenLabs/THIRD_PARTY_NOTICES.md` with redistributed adapted code.

The deployed product retains its stable application, credential, signing, Expo,
and service identities. Independent forks must configure their own Apple team,
bundle identifiers, Expo project, telemetry, and API credentials before distributing
an application. The CLI uses each user's own Keychain or explicit environment key.
Never distribute a personal provider key in a public app. The optional existing
private-beta bootstrap remains a separate deployment feature and requires an
operator-provided secret outside source control.

GitHub publishes Expo updates only when the repository variable
`ELEVENLABS_PUBLISH_ENABLED=true` and `EXPO_TOKEN` are configured. Forks have no
publication enabled by default. Native installation and device tests require
their documented explicit authorization.

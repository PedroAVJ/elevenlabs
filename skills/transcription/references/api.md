# ElevenLabs speech-to-text quick reference

- Endpoint: `POST https://api.elevenlabs.io/v1/speech-to-text`
- Auth: send `xi-api-key: $ELEVENLABS_API_KEY`
- Recommended model: `scribe_v2`
- Input size limit: under `3GB`
- Input source: local `file`, `source_url`, or other supported upload source
- Language hint: `language_code` accepts ISO-639-1 or ISO-639-3 values such as `es`
- Diarization: `diarize=true`
- Speaker hint: `num_speakers` can constrain the maximum speaker count from `1` to `32`
- Diarization tradeoff: `diarization_threshold`
  - higher value: fewer split speakers, more risk of merging two people together
  - lower value: more chance of splitting one person into multiple speakers
- Timestamp granularity: `none`, `word`, `character`
- `no_verbatim=true` removes filler words, false starts, and non-speech sounds
- `keyterms` can bias recognition toward domain jargon, but incur extra cost
- `use_multi_channel=true` is for separate-per-channel audio, not normal single-track meetings

Official docs used for this skill:
- API auth: `https://elevenlabs.io/docs/api-reference/authentication`
- Create transcript: `https://elevenlabs.io/docs/api-reference/speech-to-text/convert`
- Speech-to-text overview: `https://elevenlabs.io/docs/capabilities/speech-to-text`
- Realtime guide and SDK examples: `https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/server-side-streaming`

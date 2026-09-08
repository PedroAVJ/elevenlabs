# Local speech fixtures

Speech recordings are not distributed in this repository. To run the opt-in live
transcription test, supply a WAV file that you are authorized to send to your own
provider account through `ELEVENLABS_REALTIME_LIVE_AUDIO_FILE`, and supply the
dedicated `ELEVENLABS_REALTIME_LIVE_API_KEY` environment key.

Use 16 kHz signed 16-bit PCM speech lasting long enough to observe an intermediate
draft. Store it in ignored local configuration or fixture storage. Never commit
private speech, customer calls, voice samples, or credentials. Tests skip the live
provider check when either required environment setting is absent.

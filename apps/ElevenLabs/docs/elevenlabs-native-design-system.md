# ElevenLabs Native Demo System

This native mapping is grounded in the current official ElevenLabs brand kit:

- Brand source: <https://elevenlabs.io/brand>
- Claude Design source: the operator-selected private design workspace.
- Product context: the iPhone app, keyboard, and Live Activity are a Scribe / ElevenAPI demonstration.

It is a demo system, not a claim that ElevenLabs has endorsed or shipped this app.

## Brand rules

- Spell `ElevenLabs` exactly.
- Use the supplied logo and 11 symbol only in black or white. Do not redraw, recolor, distort, rotate, outline, or shadow them.
- Keep at least one logo-height of clear space around the wordmark.
- Prefer the 11 symbol in app-icon and other compact holding shapes.
- Use ElevenAPI's monochrome system. Orange belongs to ElevenCreative and is not the app-wide accent.

## Native tokens

| Role | Light | Dark / inverse |
| --- | --- | --- |
| Page | `#FDFCFC` | `#000000` |
| Card | `#FFFFFF` | `#141312` |
| Sunken | `#F4F2F0` | `#0A0A0A` |
| Primary text / control | `#000000` | `#FFFFFF` |
| Secondary text | `#777169` | 62% white |
| Hairline | 12% black | 16% white |
| Recording / destructive | `#D70015` | `#FF3B30` |

Spacing follows the generated 2, 4, 8, 12, 16, 20, 24, 32, 40, and 48 point ladder. Utility controls use a 4 point radius, cards 20 points, sheets 28 points, and primary recording controls remain circular. Touch targets stay at least 44 points.

## Typography

ElevenLabs' public web surfaces pair light Waldenburg display type with Inter UI copy. The native app maps that contrast to SF Pro Display/Text so Dynamic Type, language coverage, rendering, and licensing stay platform-correct:

- Editorial titles use light weight and tight tracking.
- Interface copy uses regular or medium system weights.
- Section labels use compact uppercase text with restrained tracking.
- Timers remain tabular and monospaced.

## Surface behavior

- The containing app is paper-and-ink first and supports system light and dark appearances.
- Active recording and transcription use a true-black inverse card. Red only means a live microphone, destructive action, or error, and is always paired with a label or symbol.
- The keyboard keeps the host keyboard's familiar structure while replacing orange with the same monochrome controls and semantic red recording state.
- The Live Activity is always inverse black for legibility on the Lock Screen and Dynamic Island.
- Motion uses short system transitions and obeys Reduce Motion. No animation may imply progress that the app cannot prove.

## Native audio signal

The public ElevenLabs brand kit does not prescribe a waveform component. The
native waveform is therefore a product interaction pattern, built under the
brand rules above rather than presented as an official ElevenLabs asset.

- The waveform is the sole authored live-microphone mark. Never prefix it with
  a decorative recording dot; iOS already owns the privacy indicator, and a
  second dot steals scarce space without adding information.
- Recording uses a red, center-weighted voice ribbon whose envelope comes from
  the privacy-safe microphone level. Frame changes vary its texture, but they
  must not claim a frequency spectrum or progress value the app does not have.
- Paused expanded and Lock Screen surfaces keep the waveform footprint but use
  a static ice-blue frozen ribbon and a Control Center continuation instruction.
  The constrained minimal Dynamic Island surface replaces its recording meter
  with one native snowflake while paused, so state is not communicated by color
  alone.
- Expanded Dynamic Island and Lock Screen presentations give the waveform the
  full content width with 21 samples. Compact presentation uses 9 samples in
  the entire leading slot. Minimal uses six 1.5 pt bronze-to-gold hairlines with
  1.35 pt gaps, driven by the same real microphone envelope and linearly
  interpolated between ActivityKit samples. It intentionally has no decorative
  recording disc or ambient canned animation.
- Startup keeps the waveform low and orange. Transcription changes it to a
  monochrome processing rhythm, preserving the audio silhouette instead of
  swapping to an unrelated spinner.
- Pause and Cancel use visible labels and a 50-point minimum height. Paused UI
  keeps Cancel and uses text, not a nonfunctional Resume button, to direct the
  user to Control Center. The control row remains comfortably above the
  44-point native touch-target floor.

The product's dictation, switchback, signing, storage, Keychain, recovery, and privacy contracts are independent of this visual layer and must remain unchanged.

# iPhone dictation UX

The iPhone product has one consistent route: **Control Center prepares a
persistent Live Activity; the idle Live Activity starts dictation; active
controls pause or continue; and the keyboard sends**. Preparing the launcher
does not open Dictation Button or take the microphone. Tapping the idle card
opens Dictation Button and starts listening in the foreground. ElevenLabs does
not guess or promise an automatic switchback.

The **Dictation Button** control may also be assigned to the Action Button.
It is the same system-owned toggle and follows the same launcher contract.

## First-run onboarding

1. Explain how to add **Dictation Button** in Control Center.
2. Wait for the user to invoke the real control. Do not advance from a cosmetic
   Done button. The control creates one neutral **Ready** Live Activity and does
   not start the microphone.
3. Have the user tap the idle Live Activity. That deliberate tap opens
   Dictation Button and starts recording.
4. Explain that the filled control means **Recording**. Tapping it pauses;
   the unfilled play control means **Paused** and continues the same dictation.
   Notification Center or a held Dynamic Island also exposes Pause and Cancel.
5. After the practice session ends, explain how to add the Dictation Button keyboard
   and enable **Allow Full Access**. State plainly that the keyboard only sends.

The setup state is local. It must never claim that iOS keyboard setup is
complete merely because the containing app opened Settings.

## Verbs and surfaces

| State | Control Center / Action Button | Compact activity | Expanded activity | Keyboard |
| --- | --- | --- | --- | --- |
| Idle, launcher absent | `Dictation` / `Off`; tap shows launcher | Absent | Absent | “Start from Live Activity” |
| Idle, launcher ready | `Dictation` / `Off`; tap is idempotent | Tap opens app and starts | Start dictation | “Start from Live Activity” |
| Starting | Transition in progress; duplicates are absorbed | Progress | Progress | Progress |
| Recording | Filled `Dictation` / `Recording`; tap pauses | Status only | Pause, Cancel | Live text, Send |
| Paused | Unfilled play / `Paused`; tap continues after banking | Snowflake | Frozen waveform, continuation instruction, Cancel | Current text, Send |
| Sending | Temporarily non-actionable | Progress | Progress | Refining text, optional Send now |
| Completed | Non-actionable until delivery resolves | Ready launcher | Ready launcher | Send or Idle |
| Cancelled/inserted | `Off`; launcher starts a new session | Tap opens app and starts | Start dictation | Idle |
| Failed | `Off`; retry starts only when safe | Failure status until recovery | Failure status | Recovery only |

There is no dashboard record button, keyboard Start button, or automatic
host-app return. The idle Live Activity is the deliberate recording launcher.

## System-control launcher handoff

The control is a `ControlWidgetToggle` backed by a Boolean `SetValueIntent`
that also conforms to `AudioRecordingIntent` and `LiveActivityIntent`. From Off,
the intent asks the existing `DictationEngine` to create or reuse one idle Live
Activity and returns without touching audio. It sets `openAppWhenRun` to false.
The idle card and its expanded Start button use the app-owned
`StartDictationFromLiveActivityIntent`, which opens
`elevenlabs://live-activity/start`; the foreground app then starts the recorder
and replaces the idle card with the mandatory recording activity. On iOS 26 the
control still declares background plus dynamic foreground modes for active
pause and resume; iOS 18-25 use the foreground-continuation compatibility API.

Only active recording is the Boolean On value. Off and Paused are unfilled.
The optimistic Showing state uses `waveform`; Paused uses `play.fill` so the next action is
explicit. WidgetKit owns the control's sizes, title placement, Liquid Glass,
filled treatment, and light/dark appearance.

Opening Dictation Button manually during a headless session reads the same App Group
state and presents the matching recording, paused, or transcription status. It
does not construct another recorder.

## Live Activity lifecycle

The recording process publishes elapsed time, microphone level, and a bounded
visualization frame about four times per second. One serialized heartbeat awaits
each ActivityKit update before taking the next sample, preventing continuous
generation invalidation from freezing the visible meter. Pausing stops and
deactivates the current recorder, finalizes its exact audio file, releases media
focus, and transcribes the segment into the shared session. The next Control
Center or Action Button invocation starts a fresh file in the same logical
dictation once that segment is safely banked. Paused time contributes no audio
bytes. Session-scoped intent UUIDs make stale controls harmless.

The idle compact activity opens Dictation Button and starts listening; the
expanded idle card presents the same action as a labeled Start button. Once a
session is active, compact taps are status-only. Pause and Cancel are real
buttons only in the expanded Lock Screen, Notification Center, or Dynamic
Island presentation. Paused expanded UI keeps Cancel, removes Resume, and
directs the user to Control Center. Send remains owned by the keyboard because
it must claim the current insertion point before transcription.

The expanded and Lock Screen presentations use the waveform as the primary
session surface: it spans the available width above two equal, labeled controls.
There is no app-authored recording dot. Compact mode gives its entire leading
slot to a deliberately high-motion waveform and keeps elapsed time trailing
around the camera housing. WidgetKit receives real content frames rather than
an app-authored perpetual animation. All expanded controls remain at least 50
points high.

Every recording-state Live Activity intent finishes its state transition before
returning to the system. Pause and Cancel use the audio-recording intent
contract for a consistent recording-control lane. Continuation deliberately
uses that same contract so the fresh recorder segment begins without opening
the containing app.

Completion and cancellation close the recording session by atomically turning
its Live Activity back into the idle launcher. A late recording heartbeat is
session-gated so it cannot overwrite that Ready state. If the card was dismissed
while terminal work was queued, ActivityKit receives one replacement launcher.

## Keyboard delivery

The custom keyboard is not a replacement typing keyboard and contains no
QWERTY, number, or symbol planes. While idle it only tells the user to start
from the Live Activity. During recording or pause it displays the best current
Scribe Realtime text above one full-width Send button. Send publishes progress
immediately, synchronously claims the current insertion context, and stops the
session. While batch Scribe refines the durable recording, the keyboard retains
the live text and offers Send now. Tapping it inserts the live draft immediately;
waiting lets the better batch result insert automatically. An atomic delivery
source claim guarantees that only one path can insert.
The intent-backed control keeps stable identity across polling, preventing a
just-opened keyboard from rebuilding its recognizer under the first tap. If
the destination changes or rejects custom keyboards, recovery keeps the
transcript instead of guessing.

The Control Center toggle is intentionally non-actionable while transcription
or delivery is in flight. Once insertion or cancellation reaches a terminal
state, the control returns to Off and the persistent launcher reports Ready.
There is no overwrite window.
The live preview never becomes a durable delivery
result unless the user explicitly claims it, and Send now is not eligible until
the final stopped source has finished its realtime stream.

## Implementation map

- `ElevenLabsLiveActivityWidget.swift`: Control Widget, status rendering, and
  expanded Pause/Cancel controls plus paused continuation guidance.
- `LiveActivityControlIntents.swift`: headless launcher preparation, the idle
  activity start URL, typed policy-refusal continuation, and session commands.
- `DictationEngine.swift`: headless segmented recorder, transcription, and
  Live Activity plus dual-transcription lifecycle.
- `AppModel.swift`: visible-app compatibility, recovery, dual transcription,
  and command monitor.
- `ElevenLabsClient.swift`: batch upload plus best-effort realtime WebSocket and
  growing PCM reader.
- `DictationLiveActivity.swift`: session serialization, idle launcher reuse,
  and terminal return to Ready.
- `ContentView.swift`: onboarding, reactive recording, frozen pause, and manual
  swipe handoff.
- `KeyboardView.swift`: Full Access recovery, live transcript, and send-only
  delivery UI.

## Verification boundary

Compilation and automated tests prove source structure, state serialization,
session guards, launcher-return ordering, and exactly-once bookkeeping. They cannot
prove system-owned presentation, background intent execution, microphone
continuity, or insertion into ChatGPT or Claude. Use the physical-device matrix
in `ios-keyboard-roundtrip-spec.md` before calling the interaction accepted.

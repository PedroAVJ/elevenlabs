# iPhone manual dictation round-trip specification

This is the release contract for the iPhone containing app, Control Widget,
Live Activity, and keyboard extension. Starting, pausing, and continuing from
the system surfaces has two deliberate stages: Control Center leaves the
current host visible while it prepares the launcher, then tapping the idle Live
Activity opens Dictation Button and starts recording. Active pause and continue
actions remain headless.

## Required sequence

1. The user invokes **Dictation Button** from Control Center or assigns the
   same control to the Action Button.
2. The Boolean value intent creates or reuses one neutral **Ready** Live
   Activity. It does not open Dictation Button or activate the microphone.
3. The user taps the idle Live Activity. Dictation Button opens and starts one
   shared recording; the idle card is replaced by the mandatory recording
   activity before audio activation.
4. The system-filled control reads **Recording**. Tapping it pauses, banks the
   exact segment, and changes the unfilled control to a play mark and **Paused**.
5. Tapping the paused control continues the same dictation with a fresh audio
   segment. The expanded Live Activity also pauses or cancels the session; a
   compact tap is status-only once recording has started.
6. The user selects the Dictation Button keyboard in the destination field. The
   keyboard shows the best current realtime text and Send while the shared
   session is recording or paused.
7. Send stops the session and starts/refines the complete batch transcription.
   The user may tap Send now to insert the live draft immediately, or wait for
   the batch result to insert automatically. Exactly one path inserts through
   the writable field that owns focus then. The recording activity returns to
   its idle launcher state.

## Invariants

- Control Center prepares the persistent launcher; the idle Live Activity is the
  recording start surface. There is no keyboard or dashboard Start action.
- A second control press while recording pauses; it cannot create another
  recorder or overwrite the session UUID. A press while paused starts one fresh
  continuation segment on that same session after the paused segment is banked.
  Transitional, transcription, and unresolved delivery phases absorb control
  presses instead of reinterpreting a stale Boolean value.
- A completed transcript and keyboard insertion remain protected by the shared
  state lock. The system toggle cannot start a replacement recorder while that
  delivery is unresolved. The text lands exactly once before a fresh session
  can start; no outcome may overwrite or discard it.
- Realtime is a best-effort preview, never the recovery source of truth. Its
  network failure cannot stop, discard, or fail the durable batch recording.
  Send now is eligible only after the batch worker reaches the final stopped
  segment; a live claim and batch completion use the same lock and cannot both
  own insertion.
- Expanded recording UI has Pause and Cancel. Expanded paused UI has Cancel and
  an instruction to continue from Control Center. The keyboard has neither
  lifecycle control.
- The Control Widget uses only system rendering: title **Dictation**; Off with
  the generic `mic.fill`; Showing, Recording, and Resuming with `waveform`; and
  Paused with the unfilled `play.fill`. Its value text follows Off, Showing,
  Recording, Pausing, Paused, and Resuming.
- Pause stops and deactivates the recorder, finalizes and banks that exact file,
  and releases media focus. Control Center starts a fresh file in the same
  session after banking; the paused interval contributes zero bytes. Cancel
  discards recoverable audio and returns the activity to its idle launcher.
- The recording waveform responds to actual microphone level. The paused
  minimal presentation is a snowflake, while expanded pause is a static
  ice-blue frozen waveform.
- The app never claims that opening Keyboard Settings proves the keyboard was
  added or granted Full Access.
- Opening or foregrounding Dictation Button from the Control Widget itself,
  automatic host return, explicit ChatGPT/Claude return choices, direct bundle
  activation, generic suspension, and guessed previous-app APIs are forbidden.
  The separate idle Live Activity tap deliberately opens Dictation Button.
- Completed and cancelled sessions atomically return their Live Activity to
  the idle launcher. A late heartbeat cannot overwrite that Ready state.

## Retired automatic switchback

Earlier builds attempted to identify a keyboard host and open a fixed URL for
ChatGPT, Claude, Notes, and other cataloged apps. Physical results were not
consistent enough to make that a product expectation. On 2026-08-24 the
automatic path was explicitly retired. The idle launcher now opens only
Dictation Button; manual home-bar swipe remains the sole return expectation.

The reference-derived host capture, resolver, and catalog remain dormant so the
evidence is not accidentally rewritten. Their hashes are pinned in
`protected-switchback.sha256`. Active `AppModel` code and `KeyboardView` are not
part of that hash baseline because they enforce the new product boundary.
Structural tests strip compile-disabled Swift and fail if the active app calls
`HostAppSwitcher.open` or if the keyboard reconnects its old Start action.

Do not reconnect dormant switchback code as a bug fix. That would be a product
change requiring an explicit decision, a fresh reference-app inspection, and a
new physical acceptance matrix.

## Physical-device acceptance matrix

Run every required row on the release build intended for distribution. Record
the iPhone model, iOS version, app version/build, destination app version, and
whether the app was warm, cold, or evicted.

### First use

- Fresh install shows the Control Center step before keyboard setup.
- The onboarding cannot advance merely by reopening Dictation Button.
- Invoking the real control shows one Ready Live Activity and advances the
  practice state without starting the microphone.
- The current destination remains visible after Control Center dismisses.
- Tapping the idle Live Activity opens Dictation Button and starts recording.
- After the practice session ends, onboarding opens the correct Keyboard
  Settings destination and accurately requests Allow Full Access.

### Start and return

- From both ChatGPT and Claude, invoke the Control Center control.
- Verify the destination stays visible, no recording starts, one Ready Live
  Activity appears, and the control returns to unfilled **Off**.
- Tap the idle activity; verify Dictation Button opens, one recording starts,
  and the control becomes filled with **Recording**.
- Repeat with the control assigned to the Action Button if configured.
- Press the control again during recording; verify it pauses the same session,
  releases the microphone, becomes unfilled, and shows play plus **Paused**.
- Press the paused control; verify the same session continues with a fresh
  segment, the control refills, and prior audio remains ordered.
- Press the control while Send is transcribing; verify it does not start or
  overwrite a session and the current result is retained.

### Live Activity

- Verify the compact waveform visibly responds to quiet and loud speech.
- With the idle launcher visible, tap the compact activity and verify it opens
  Dictation Button and starts one session.
- During recording, tap the compact activity; it may open Dictation Button
  status but must not pause, resume, cancel, or start another session.
- Expand from Notification Center and, on supported hardware, by holding the
  Dynamic Island. Recording must show Pause and Cancel.
- Pause; verify the microphone releases and the activity becomes blue/frozen
  with Cancel and a Control Center continuation instruction.
- Invoke the paused Control Center or Action Button control; verify a fresh
  audio file continues the same session, the waveform becomes live, the earlier
  phrase is retained in order, and no paused-time audio is sent.
- Cancel from both recording and paused states; verify audio is discarded and
  the Live Activity returns to Ready.

### Keyboard and delivery

- With no active session, the keyboard has no record button and says to start
  from the Live Activity.
- With recording active, the keyboard fills with updating text above one Send
  button and has no Pause, Resume, Cancel, Start, QWERTY, number, or symbol
  controls. Verify light and dark system appearance.
- In ChatGPT and Claude, exercise both outcomes: tap Send now during refinement,
  then repeat and wait for batch. Each transcript must insert once at the current
  writable cursor and the activity must return to Ready.
- Speak identical phrases in consecutive VAD segments and verify neither is
  dropped from the live preview.
- Race Send completion against another Control Center press repeatedly. Verify
  the transitional press is absorbed, the completed phrase inserts exactly
  once, and no phrase disappears or appears twice.
- Change the cursor after Send and repeat after presenting the ElevenLabs
  keyboard in a different writable field. Verify the completed transcript
  follows the live keyboard cursor exactly once without an Insert Here prompt.
- Deny Full Access and verify the keyboard shows accurate recovery without
  preventing Control Center from starting a recording.

### Lifecycle and failure

- Repeat after cold launch and process eviction.
- Test lock-screen presentation, microphone denial, network failure, retry,
  cancellation during startup, and cancellation during transcription.
- Interrupt only the realtime connection and verify batch still completes and
  inserts. Fail batch after Send now and verify the live insertion remains
  successful without a duplicate or stale Retry state.
- Verify terminal activity return to the Ready launcher after success and
  cancellation.
- Verify no automatic ChatGPT, Claude, Notes, or Home Screen transition occurs
  anywhere in the active flow.

A successful build, signed install, intent return value, or processed TestFlight
build is not acceptance for these system-owned interactions.

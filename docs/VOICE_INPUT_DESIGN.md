# On-Device Voice Input Design

Status: Implemented; physical-device acceptance pending
Last updated: August 2, 2026

## Summary

Add a microphone button to the chat composer. Tapping it starts live speech
transcription, displays partial text in the existing composer, and tapping it
again finishes the utterance. The resulting text remains an editable draft;
the app never sends it automatically.

Use Apple's `SpeechAnalyzer` and `SpeechTranscriber` from the Speech framework.
This is the preferred design because the app already targets iOS 26.5 and the
new transcription model runs entirely on device. The first use of a locale may
download Apple-managed model assets, but recorded audio is not uploaded for
recognition.

The supporting Apple API research and source links are in
[`VOICE_INPUT_RESEARCH.md`](VOICE_INPUT_RESEARCH.md).

## Goals

- Let users dictate a chat message from the existing input bar.
- Keep speech recognition entirely on device.
- Show low-latency partial transcription while recording.
- Preserve existing typed text and leave the transcript editable before send.
- Handle permission, model download, audio interruption, cancellation, and view
  lifecycle without leaking microphone or analyzer resources.
- Keep audio/transcription concerns out of `ChatDetailView` and
  `ChatInputBar` behind one small interface.

## Non-goals

- Sending a message automatically when recording stops.
- Saving or attaching recorded audio.
- Transcribing imported audio files.
- Supporting iOS releases before iOS 26.
- Falling back to Apple server speech recognition or a third-party service.
- Adding a language picker in the first version.
- Continuing recording in the background.

## Product Decisions

### Interaction

1. In the idle state, a microphone button appears between the text field and
   send button.
2. Tapping the microphone starts a lazy preparation flow: request microphone
   permission, resolve the current locale, install its model if necessary,
   configure audio, and begin transcription.
3. While preparing, the microphone button shows progress and repeated taps are
   ignored. If a model download is required, a short status such as
   "Preparing English transcription…" appears above the composer.
4. While recording, the microphone changes to a red stop button and the input
   bar shows an obvious red recording indicator. Partial transcription appears
   in the text field.
5. Tapping stop ends capture and waits for final transcription. The final text
   remains in the composer for editing; the user taps Send separately.
6. Navigating away, deleting/switching the conversation, or backgrounding the
   app cancels recording and restores the draft that existed before recording.

The interaction is tap-to-start/tap-to-stop rather than press-and-hold. It is
more accessible, supports longer dictation, and gives model preparation a clear
place in the flow.

### Draft composition

Starting dictation snapshots the current composer text as `baseDraft`. The
visible composer is derived from `baseDraft` plus the current utterance:

- Empty base: `"transcribed words"`
- Non-empty base ending in whitespace: `"typed text transcribed words"`
- Non-empty base without trailing whitespace: insert one space before the
  transcript.

The text field is disabled during preparation, recording, and finalization so
user edits cannot race partial-result replacement. On successful finalization,
the combined text becomes the normal editable `inputText`. On cancellation or
failure before a useful final result, `baseDraft` is restored.

### Relationship to response streaming

Voice input and assistant response streaming are mutually exclusive:

- The microphone is disabled while `isStreaming` is true.
- Send remains disabled while voice input is preparing, recording, or
  finalizing.
- Starting an assistant stream is impossible until transcription has returned
  to idle.
- `send()` also guards against every active voice state; button disabling alone
  is not relied on because submit actions and future callers can invoke it.

This keeps the current send/stop response button behavior unchanged and avoids
competing meanings for the same stop action.

## Technical Decision

### Chosen Apple path

Use:

- `SpeechTranscriber` for locale-specific, entirely on-device speech-to-text.
- `SpeechAnalyzer` for the live analysis session and finalization lifecycle.
- `AssetInventory` to inspect, download, and reserve the required locale model.
- `AVAudioEngine` and an input-node tap for iOS 26 live microphone capture.
- `AVAudioConverter` to convert microphone buffers to the analyzer's required
  format.
- `AVAudioSession` with `.playAndRecord` and `.spokenAudio`, matching Apple's
  iOS 26 live-transcription sample. Bluetooth input may be enabled where the
  active route supports it.

Do not use `SFSpeechRecognizer`: the project deployment target is iOS 26.5, so
its older request/callback interface and separate speech authorization add no
compatibility value. Do not use the iOS 27 `CaptureInputSequenceProvider` yet,
because it would raise the minimum runtime beyond the current target.

### Runtime capability policy

Voice input is available only when all of these are true:

- Microphone permission is granted or not yet determined.
- `SpeechTranscriber.isAvailable` is true.
- `SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)` resolves a
  locale.
- `AssetInventory` reports the model installed or downloadable.
- A usable microphone input route exists.

Checks happen at runtime; no supported-locale list is hard-coded. Before the
first attempt, the microphone remains enabled because permission, assets, and
locale support are resolved lazily. A permanent failure for the current runtime
(unsupported hardware or locale) leaves it disabled with an accessibility hint.
A recoverable failure (permission not yet granted, offline asset download, audio
route, interruption, or analyzer failure) leaves it enabled so tapping retries.
Permission denial directs the user to Settings. A language picker can be added
later without changing the transcription module's external interface.

## Module Design

Add one deep module, `VoiceInputSession`, whose implementation owns permissions,
locale/model preparation, audio capture and conversion, analyzer input, result
aggregation, finalization, interruptions, and cleanup.

The external seam is intentionally small:

```swift
@MainActor
@Observable
final class VoiceInputSession {
    private(set) var state: VoiceInputState = .idle
    private(set) var transcript: String = ""

    func start() async
    func finish() async
    func cancel() async
}
```

`ChatDetailView` and tests use this interface. Framework types such as
`SpeechAnalyzer`, `SpeechTranscriber`, `AVAudioEngine`, `AVAudioConverter`, and
`AssetInventory` do not cross the seam.

Suggested state model:

```swift
enum VoiceInputState: Equatable {
    case idle
    case preparing(VoicePreparation)
    case recording
    case finalizing
    case unavailable(String)
    case failed(String)
}

enum VoicePreparation: Equatable {
    case requestingPermission
    case resolvingLocale
    case downloadingModel(progress: Double?)
    case configuringAudio
}
```

The interface invariants are:

- `start()` is effective only from `idle`, `unavailable`, or `failed`.
- `finish()` is effective only from `recording` and performs graceful analyzer
  finalization so the last words are not lost.
- `cancel()` is idempotent from every state, discards the current utterance,
  releases resources, and returns to `idle`.
- `transcript` contains only the current utterance, not the pre-existing typed
  draft.
- All published state is main-actor isolated.
- At most one audio tap, analyzer session, result consumer, and preparation
  task exists at a time.
- Every terminal path removes the audio tap, stops the engine, finishes the
  analyzer input continuation, deactivates the audio session, and clears task
  references.

`VoiceInputSession` rechecks asset status on each `start()` rather than caching
an installed Boolean. The installation request reserves the resolved locale for
the app. Do not release that reservation after each utterance because voice
input will reuse it. If a future language picker changes locale, install and
reserve the replacement first, then call `release(reservedLocale:)` for the old
locale. Surface reservation-limit failures as unavailable rather than evicting
an asset silently; the first version reserves at most the current locale.

### Internal seams

The implementation may use private adapters for deterministic unit tests:

- Microphone permission adapter.
- Speech asset preparation adapter.
- Audio capture adapter yielding normalized buffers.
- Analyzer adapter yielding partial/final text results.

These remain internal to `VoiceInputSession`; they should not become general app
interfaces unless a second production adapter appears.

## State Machine

```text
                         permission/model/audio failure
                        ┌───────────────────────────────┐
                        ▼                               │
idle ── start ──▶ preparing ── ready ──▶ recording ── stop ──▶ finalizing
 ▲                    │                  │    │                       │
 │                    │ cancel           │    │ cancel/interruption   │ final
 │                    ▼                  │    ▼                       │ result
 └────────────────── idle ◀──────────────┴── idle ◀──────────────────┘

preparing/recording/finalizing ── failure ──▶ failed ── dismiss/retry ──▶ idle
preparing ── unsupported/denied ────────────▶ unavailable ── settings/retry ─▶ idle
```

An audio-session interruption is cancellation, not graceful finalization,
because capture continuity is no longer guaranteed. Route changes that remove
the input route follow the same path. The UI restores `baseDraft` and presents a
short recoverable error.

## Audio and Transcription Flow

### Start

1. `ChatDetailView` snapshots `inputText` into `baseDraft` and calls `start()`.
2. Request microphone permission with
   `AVAudioApplication.requestRecordPermission()` if needed.
3. Resolve a supported locale equivalent to `Locale.current`.
4. Construct a `SpeechTranscriber` configured for volatile results. Audio time
   ranges are unnecessary for composer-only text.
5. Check `AssetInventory.status(forModules:)`. If required, request and install
   assets while publishing progress through `.preparing`.
6. Ask `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` for the exact
   required format.
7. Configure and activate `AVAudioSession`, install the `AVAudioEngine` input
   tap, and start the engine.
8. Convert each captured buffer to the required format and yield an
   `AnalyzerInput` into the analyzer's input stream.
9. Consume `SpeechTranscriber.results` in a separate task. Maintain finalized
   and volatile portions and publish their combination through `transcript`.

### Result aggregation

Treat volatile results as replacement text, not append-only tokens:

```text
published transcript = finalizedPrefix + currentVolatileResult
```

When a final result arrives, append it once to `finalizedPrefix` and clear the
volatile portion. This avoids duplicated words as hypotheses are revised.
Whitespace joining belongs inside the module so callers receive one clean
utterance string.

### Graceful stop

1. Stop the audio engine and remove the input tap so no new buffers arrive.
2. Finish the analyzer input continuation.
3. Call `finalizeAndFinishThroughEndOfInput()`.
4. Continue consuming results until the sequence ends, preserving the last
   final update.
5. Tear down audio/analyzer resources and return to `idle` without clearing the
   final `transcript` until the caller has committed it to `inputText`.

### Cancel

1. Stop capture and remove the tap immediately.
2. Finish the input continuation.
3. Call `cancelAndFinishNow()` and cancel owned tasks.
4. Deactivate the audio session and clear the utterance.
5. Return to `idle`.

Cleanup must be centralized and idempotent so errors from any setup stage can
use the same path.

## UI Integration

### `ChatDetailView`

Add:

- A `VoiceInputSession` state instance.
- A private `baseDraft` snapshot.
- Start, finish, cancel, and transcript-composition handlers.
- Cancellation on disappearance, when the scene becomes inactive, and when the
  bound conversation identity changes. Conversation switching/deletion must
  restore the old conversation's `baseDraft` before the new draft is shown.
- A voice-state guard in `send()` in addition to disabled controls.

The view owns draft policy; the transcription module owns speech behavior. No
transcript is persisted to SwiftData until the existing Send action creates a
user `Message`.

### `ChatInputBar`

Extend its interface with derived voice state and actions, without importing
Speech or AVFAudio:

```swift
ChatInputBar(
    text: $inputText,
    isStreaming: isStreaming,
    voiceState: voiceInput.state,
    onStartVoiceInput: startVoiceInput,
    onFinishVoiceInput: finishVoiceInput,
    onSend: send,
    onStop: stopStreaming
)
```

Visual behavior:

- Idle: `mic.circle.fill` button, enabled when not streaming.
- Preparing: progress indicator in the microphone button position.
- Recording: red `stop.circle.fill`, red recording dot, and "Listening…".
- Finalizing: progress indicator and "Finishing transcription…".
- Permanently unavailable: disabled microphone with an accessibility hint.
- Recoverable failure: normal microphone appearance; tapping retries and the
  parent surfaces the reason in the existing alert system.

Accessibility:

- Labels: "Start voice input" and "Stop voice input".
- Recording value: "Listening".
- Preparation progress is announced when model download starts and finishes.
- Color is never the only recording signal; icon, text, and accessibility value
  all change.

## Permissions, Privacy, and Storage

Add to `ai-chat/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>AI Chat uses the microphone to transcribe messages on this device.</string>
```

No entitlement is required. The selected `SpeechAnalyzer` path does not call
`SFSpeechRecognizer.requestAuthorization`, so the design does not add
`NSSpeechRecognitionUsageDescription`.

Privacy behavior:

- Captured audio is held only in memory long enough to feed the analyzer.
- Audio is never written to disk, attached to a message, logged, or uploaded.
- Apple-managed speech model assets may require a network download before first
  use for a locale; transcription after installation remains on device.
- The resulting text follows the existing chat behavior. If the conversation
  uses a cloud provider, the text is sent when the user explicitly taps Send.
  If it uses Apple Intelligence, the text remains on device.

The app should not claim that the whole chat remains local merely because voice
transcription is local; locality still depends on the selected chat provider.

## Error Handling

Map expected failures to concise user actions:

| Failure | UI behavior |
| --- | --- |
| Microphone permission denied | Restore draft; explain how to enable Microphone access in Settings |
| Current locale unsupported | Restore draft; report that on-device transcription is unavailable for the current language |
| Model download unavailable/offline | Restore draft; ask the user to connect and retry; never switch to server recognition |
| Model download in progress | Keep preparing state and show progress; allow navigation to cancel |
| No microphone route | Restore draft; ask the user to connect or enable an input device |
| Audio session interrupted/route lost | Cancel utterance, restore draft, and report that recording stopped |
| Analyzer or conversion failure | Cancel and clean up; restore draft; show a retryable generic transcription error |
| User navigates away/backgrounds app | Cancel silently and restore the pre-recording draft |

Raw framework error codes should not be shown to users. Preserve underlying
errors for debugging without logging transcript or audio content.

## File Changes for Implementation

Planned application changes:

- Add `ai-chat/VoiceInputSession.swift` for the module and state model.
- Update `ai-chat/ChatDetailView.swift` to own the session and draft policy.
- Update `ChatInputBar` in `ai-chat/ChatDetailView.swift` with microphone UI.
- Update `ai-chat/Info.plist` with microphone purpose text.
- Update `docs/ARCHITECTURE.md` after implementation to include the module and
  voice-input data flow.
- Update `README.md` after implementation to advertise the feature and device
  requirements.

No SwiftData schema, entitlement, chat provider, or networking change is
required.

## Test Strategy

### Unit tests

Test through the `VoiceInputSession` interface using internal fake adapters:

- Valid state transitions for start, finish, cancel, retry, and repeated taps.
- Permission denial and unsupported locale never start capture.
- Model installation progress reaches the published preparation state.
- Partial-result revisions replace volatile text rather than duplicating it.
- Final results append exactly once and survive graceful finish.
- Cancellation clears the utterance and invokes every cleanup operation once.
- Setup failure after an audio tap is installed still removes the tap and
  deactivates the session.
- Interruption and input-route loss cancel recording.
- Draft-composition helper handles empty text, existing whitespace, and
  punctuation consistently.

### UI tests

- Microphone button is present and disabled during response streaming.
- Recording state exposes a visible stop control and accessibility labels.
- Idle controls expose the expected accessibility labels and button ordering.

System permission prompts and speech models are not deterministic in Simulator.
Keep app-level UI automation to deterministic idle/streaming states; verify
recording/finalizing rendering with SwiftUI previews during development, cover
state and draft behavior in unit tests, and exercise the end-to-end flow in the
physical-device acceptance pass. Do not add a production-wide abstraction only
to inject a fake into UI automation.

### Physical-device acceptance

Test on at least one supported iPhone and iPad:

- First use with model download, including cancellation and retry.
- Airplane-mode transcription after the model is installed.
- Fast speech, pauses, punctuation, and correction of volatile results.
- Bluetooth and built-in microphone routes.
- Phone/Siri interruption, route removal, screen lock, and app backgrounding.
- Permission denied, then enabled from Settings.
- Cloud-provider chat to confirm only text is transmitted on Send.
- Apple Intelligence chat to confirm the complete voice-to-chat flow is local.

## Acceptance Criteria

- The chat page has an accessible microphone button next to the composer.
- `NSMicrophoneUsageDescription` is present with a specific on-device
  transcription purpose string.
- Tapping it starts live transcription after required preparation.
- A first-use model download shows progress, can be cancelled safely, and can be
  retried without restarting the app.
- Partial text updates in the composer and final text remains editable.
- Stopping never sends a message automatically and does not lose trailing words.
- Existing draft text is preserved across successful dictation and restored on
  cancellation or failure.
- Audio is never persisted or uploaded for recognition.
- Unsupported locales and offline model-installation failures do not fall back
  to server recognition.
- Voice controls are unavailable while an assistant response is streaming.
- All stop, cancel, failure, interruption, navigation, and background paths
  release audio and analyzer resources.
- Targeted unit tests pass and the flow is accepted on a physical device.

## Open Follow-ups

These are intentionally deferred and do not block the first version:

- A language picker for users whose spoken language differs from
  `Locale.current`.
- Pre-downloading a selected locale model from Settings.
- Automatic end-of-speech detection.
- Optional insertion at the text cursor instead of appending to the draft.
- Adoption of `CaptureInputSequenceProvider` after the minimum OS moves to
  iOS 27.

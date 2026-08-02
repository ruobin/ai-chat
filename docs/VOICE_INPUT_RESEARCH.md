# Apple On-Device Speech-to-Text for iOS

Research date: August 2, 2026. Sources are limited to Apple documentation,
WWDC sessions, and Apple sample code.

## Recommendation

- Use `SpeechAnalyzer` with `SpeechTranscriber` on iOS 26 and later. It is
  Apple's current, entirely on-device path, is designed for low-latency live
  transcription and longer conversational audio, and has explicit APIs for
  downloading and managing its models.
- Use `SFSpeechRecognizer` only as an iOS 13-25 fallback when supporting those
  releases is required. Set `requiresOnDeviceRecognition = true` only after the
  locale-specific recognizer reports `supportsOnDeviceRecognition == true`.
- Do not silently fall back to server recognition. If the requested locale or
  device lacks an on-device model, disable voice input or offer a clearly
  disclosed alternative.

## Comparison

| Area | `SpeechAnalyzer` + `SpeechTranscriber` | `SFSpeechRecognizer` on device |
| --- | --- | --- |
| Availability | iOS/iPadOS 26+, Mac Catalyst 26+ | `SFSpeechRecognizer`: iOS 10+; `requiresOnDeviceRecognition` and `supportsOnDeviceRecognition`: iOS 13+ |
| Processing | `SpeechTranscriber` is entirely on device | On device only when both the request requires it and the locale/device recognizer supports it |
| Intended use | Live or prerecorded, low latency, long-form, conversational, and distant audio | Short-form dictation; Apple documents a one-minute task-duration limit |
| Results | Throwing `AsyncSequence`; optional volatile results followed by final results; text is an `AttributedString` with optional audio timing | Callback/delegate results; optional partial results; `bestTranscription.formattedString` and segment metadata |
| Models | Explicit `AssetInventory` status, reservation, download, progress, release, and system-managed updates | No app-facing model installation API; availability depends on the locale/device's system speech assets |
| Locale checks | `SpeechTranscriber.isAvailable`, `supportedLocales`, `installedLocales`, and `supportedLocale(equivalentTo:)` | `SFSpeechRecognizer.supportedLocales()`, then instantiate for one locale and check `supportsOnDeviceRecognition` and `isAvailable` |
| Stop behavior | End input and finalize to preserve final text, or cancel immediately and discard pending work | `finish()` processes accepted audio; `cancel()` stops the task and requires capture-resource cleanup |
| Privacy declaration | Microphone permission for live audio; Apple's on-device sample has no speech-recognition usage key | Speech-recognition authorization and usage description are required by the recognizer API, plus microphone permission for live audio |

Sources: [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber),
[requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition),
[SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer), and
[WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/).

## SpeechAnalyzer and SpeechTranscriber

### Availability and capability checks

`SpeechAnalyzer`, `SpeechTranscriber`, and `AssetInventory` are available from
iOS 26. The API declaration alone does not establish that the new model runs on
a particular device. Apple directs apps to check `SpeechTranscriber.isAvailable`
for hardware/capability support and to query locale support at runtime. If it is
unavailable, Apple suggests disabling the feature or considering
`DictationTranscriber`, an iOS 26 API backed by the older dictation model and
compatible with older hardware.

Do not ship a hard-coded locale list. Apple's supported set can change as
models update. Resolve a user locale with
`await SpeechTranscriber.supportedLocale(equivalentTo:)`, or compare BCP-47
identifiers against `supportedLocales`; use `installedLocales` only to decide
whether a download is needed. `supportedLocales` includes downloadable locales.

Sources: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber), and
[supportedLocale(equivalentTo:)](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocale(equivalentto:)).

### Model assets

Required machine-learning assets are downloaded from Apple's servers but used
on device. The system stores, shares, retains, and automatically updates them;
they do not increase the app download size or run inside the app's memory space.
An initial locale may therefore require network access and visible download
progress before transcription can start.

The reliable sequence is:

1. Create the configured `SpeechTranscriber`.
2. Check `SpeechTranscriber.isAvailable` and resolve a supported locale.
3. Check `AssetInventory.status(forModules:)` or `installedLocales`.
4. Obtain `assetInstallationRequest(supporting:)` and call
   `downloadAndInstall()` when the status is `.supported` rather than
   `.installed`.
5. Surface the request's `Progress`. Treat `.unsupported` as unavailable and
   `.downloading` as not ready.

Locale assets consume app-specific reservations. The allowed number is dynamic
(`maximumReservedLocales`); release unused reservations with
`release(reservedLocale:)`. Assets persist across launches and are shared, but
the system may unsubscribe an app from assets it has not used for a while, so
status must be rechecked rather than persisted as an app Boolean.

Sources: [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory),
[AssetInventory.Status](https://developer.apple.com/documentation/speech/assetinventory/status), and
[WWDC25 model discussion](https://developer.apple.com/videos/play/wwdc2025/277/?time=423).

### Live audio pipeline on iOS 26

Apple's iOS 26 sample uses this pipeline:

1. Request microphone access.
2. Configure and activate `AVAudioSession` as `.playAndRecord` with mode
   `.spokenAudio`.
3. Install an `AVAudioEngine.inputNode` tap and expose incoming
   `AVAudioPCMBuffer` values through an `AsyncStream`.
4. Install required speech assets, then ask
   `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` for the modules'
   format. A `nil` result means additional assets are required.
5. Convert every input buffer to that exact format. `SpeechAnalyzer` does not
   transparently resample or convert because its timeline is sample-accurate.
6. Wrap each converted buffer in `AnalyzerInput`, yield it to an input
   `AsyncStream`, and call `analyzer.start(inputSequence:)`.
7. Independently consume `transcriber.results`. Replace the current volatile
   text when `isFinal == false`; when a final result arrives, append it and
   clear volatile text to avoid duplicates.

The WWDC sample enables `.volatileResults` for immediate UI feedback and
`.audioTimeRange` when text/audio synchronization is needed. For a chat composer,
volatile text should remain draft UI state; only final text should become the
committed message input.

Sources: [WWDC25 code and transcript](https://developer.apple.com/videos/play/wwdc2025/277/?time=662),
[bestAvailableAudioFormat](https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat(compatiblewith:)), and
[Apple sample download](https://developer.apple.com/documentation/speech/bringing-advanced-speech-to-text-capabilities-to-your-app).

### iOS 27 beta capture option

Apple's current live-audio sample uses `CaptureInputSequenceProvider`, introduced
in iOS 27 beta, to configure `AVCaptureSession`, conversion, and the analyzer
input sequence without an `AVAudioEngine` tap. It is useful for an iOS 27-only
future path, but it does not replace the iOS 26 `AVAudioEngine` pipeline for an
app whose deployment target includes iOS 26.

Source: [Recognizing speech in live audio](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio).

### Finishing, cancellation, and errors

- Normal stop: stop capture, finish the app-created input continuation, then
  await `finalizeAndFinishThroughEndOfInput()`. This consumes all input and
  converts the last volatile result into final output.
- Time-bounded input: `analyzeSequence(_:)` returns the last audio time; pass it
  to `finalizeAndFinish(through:)`.
- Abort: `cancelAndFinishNow()` cancels pending work and finishes immediately.
  It does not promise final results.
- Task cancellation is cooperative. Apple's current sample lets cancellation
  stop input analysis but keeps the result consumer alive until finalization
  closes the result sequence, preventing loss of the last update.

Asset installation, analyzer start/finalization, audio conversion, and the
results sequence can all throw. Apple documents `CancellationError` when
`finalizeAndFinishThroughEndOfInput()` is ended early, but does not document one
exhaustive public `SpeechAnalyzer` error-code enum. Preserve the underlying
`Error`, classify known permission/cancellation/asset/audio-session cases for
UI, and avoid matching undocumented numeric error codes.

Sources: [finalizeAndFinishThroughEndOfInput](https://developer.apple.com/documentation/speech/speechanalyzer/finalizeandfinishthroughendofinput()),
[cancelAndFinishNow](https://developer.apple.com/documentation/speech/speechanalyzer/cancelandfinishnow()), and
[Apple live-audio cancellation sample](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio#Stop-the-capture-session).

## Legacy SFSpeechRecognizer Path

Create one `SFSpeechRecognizer(locale:)` per selected locale. Check that the
locale appears in `supportedLocales()`, the recognizer exists, and
`supportsOnDeviceRecognition` is true. Then set
`SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition = true`
before starting the task. Setting the request flag alone is insufficient: Apple
says it is honored only when the recognizer's support flag is true. When that
flag is false, recognition requires a network connection.

For live audio, install an `AVAudioEngine` input tap, append each buffer to an
`SFSpeechAudioBufferRecognitionRequest`, set `shouldReportPartialResults` when
desired, and consume the result/error callback. On normal stop, stop and remove
the tap and call `task.finish()` (or end request audio) so accepted audio is
processed. On abort or interruption, call `task.cancel()` and release capture
resources.

Important limitations:

- The framework's general guidance still says to plan for a one-minute audio
  limit and service throttling. This makes it acceptable for short chat
  dictation but inferior to `SpeechTranscriber` for long recording.
- The old API has no `AssetInventory`. WWDC25 says it relied on users adding
  languages in system settings. If a locale lacks an installed on-device model,
  the app can detect that through `supportsOnDeviceRecognition` but cannot
  initiate the model download itself.
- `isAvailable` means the recognizer service is currently available; it is not
  a substitute for `supportsOnDeviceRecognition`.
- Recognition failures arrive through the callback/delegate. Public
  `SFSpeechError` cases include `audioReadFailed`, `internalServiceError`,
  `missingParameter`, and `timeout`; also handle availability changes and task
  cancellation without showing raw error codes to users.

Sources: [requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition),
[supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition),
[SFSpeechRecognizer guidance](https://developer.apple.com/documentation/speech/sfspeechrecognizer),
[finish](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/finish()),
[cancel](https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/cancel()), and
[SFSpeechError](https://developer.apple.com/documentation/speech/sfspeecherror).

## Permissions and Privacy

For either live-audio path:

- Add `NSMicrophoneUsageDescription` with a specific purpose string. Apple says
  an app that accesses a microphone without it exits.
- Request record permission before starting capture, for example with
  `await AVAudioApplication.requestRecordPermission()` on iOS 17+.
- Keep an obvious recording indicator visible while the microphone is active.

For `SpeechAnalyzer` + `SpeechTranscriber`, Apple's iOS 26 sample requests only
microphone permission and declares only `NSMicrophoneUsageDescription`.
`SpeechTranscriber` processes speech entirely on device. Apple's definition of
`NSSpeechRecognitionUsageDescription` says that key is required for APIs that
send user data to Apple's speech-recognition servers; consequently it is not
required for this all-on-device sample path.

For `SFSpeechRecognizer`, call `SFSpeechRecognizer.requestAuthorization(_:)`
before recognition and include `NSSpeechRecognitionUsageDescription`. Apple
documents that omitting the key when calling the authorization API crashes the
app. This API-level authorization requirement applies even when the request is
configured to require on-device recognition. Live audio additionally requires
microphone permission.

Sources: [NSMicrophoneUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription),
[record permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)),
[NSSpeechRecognitionUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsspeechrecognitionusagedescription), and
[SFSpeechRecognizer.requestAuthorization](https://developer.apple.com/documentation/speech/sfspeechrecognizer/requestauthorization(_:)).

## Simulator and Device Limits

- Treat a physical device as required for acceptance testing. Model and locale
  support are device-dependent, and `SpeechTranscriber.isAvailable`,
  `supportedLocales`, and asset status are the authoritative runtime checks.
- Apple's iOS 26 WWDC sample project includes an iPhone Simulator build target,
  but Apple does not promise that `SpeechTranscriber` models are available in
  Simulator. A successful build is therefore not evidence that transcription
  is supported there.
- Apple's current iOS 27 live-audio sample explicitly does not run in iOS
  Simulator and requires a physical device with iOS/iPadOS 27 or later.
- For the legacy path, check both `isAvailable` and
  `supportsOnDeviceRecognition` in the actual environment. Do not infer support
  from OS version, locale presence, or simulator behavior.
- Microphone routes, interruptions, Bluetooth input, permissions, model
  downloads, thermal behavior, and offline operation all require real-device
  tests. Verify first use with network for model installation, then airplane
  mode after installation to prove the transcription path remains local.

Sources: [SpeechTranscriber device support](https://developer.apple.com/documentation/speech/speechtranscriber#Check-device-support),
[iOS 27 sample limitation](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio), and
[SFSpeechRecognizer availability](https://developer.apple.com/documentation/speech/sfspeechrecognizer).

## Practical Decision Matrix

| Runtime | Local voice-input choice |
| --- | --- |
| iOS 26+, `SpeechTranscriber.isAvailable`, locale supported, asset installed/downloadable | `SpeechAnalyzer` + `SpeechTranscriber` |
| iOS 26+, new model unavailable, but `DictationTranscriber` supports the locale/device | Consider `DictationTranscriber`; validate its result quality separately |
| iOS 13-25, locale recognizer has `supportsOnDeviceRecognition == true` | `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` |
| Any runtime without an installed/downloadable on-device option | Disable local voice input; do not silently upload speech |

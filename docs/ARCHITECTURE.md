# Architecture

## Overview

Parley (Xcode project/target/scheme name: `Parley`, Swift module `AIChat`)
is a single-target
SwiftUI iOS app. It has no backend of its own — it's a thin client over two
kinds of providers: Apple Intelligence's on-device model (via the
Foundation Models framework, iOS 26+), and any OpenAI-compatible
`chat/completions` HTTP API (streaming, via SSE). Local state
(conversations, messages) is persisted with SwiftData; API keys are
persisted separately in the Keychain.

```
┌─────────────────────────────────────────────────────────────────┐
│                            SwiftUI Views                          │
│                                                                     │
│  ContentView  ──────▶  ChatDetailView  ──────▶  SettingsView       │
│  (sidebar,             (message list,           (provider preset,  │
│   conversation list)    input, streaming)         API key, model,  │
│                                                    system prompt,   │
│                                                    temperature)     │
└───────────────┬─────────────────────────────────┬─────────────────┘
                │                                   │
                ▼                                   ▼
      ┌───────────────────┐              ┌────────────────────┐
      │   SwiftData        │              │   ChatSettings      │
      │   (Conversation,    │              │   (@Observable)     │
      │    Message)         │              │                     │
      └───────────────────┘              └──────────┬──────────┘
                                                        │
                                           reads/writes  │
                                                        ▼
                                               ┌──────────────────┐
                                               │  KeychainStore    │
                                               │  (API key only)   │
                                               └──────────────────┘
                │
                ▼
      ┌───────────────────┐        ┌──────────────────────────────┐
      │   ChatService       │        │   AppleIntelligenceService    │
      │   (streaming HTTP   │──────▶ │   (Foundation Models —        │
      │    client)          │        │    on-device generation)      │
      └─────────┬─────────┘        └──────────────┬───────────────┘
                │                                  │
                ▼                                  ▼
        Provider API (OpenAI, Anthropic,   Apple Intelligence
        Google, DeepSeek, xAI, OpenRouter, on-device model
        Ollama, or any custom              (no network, no key)
        OpenAI-compatible endpoint)
```

## Components

### Data layer (SwiftData)

- **`Conversation`** — id, title, timestamps, a `@Relationship` to its
  `Message`s with cascade delete, and its own provider/model override
  (`baseURLOverride` / `modelNameOverride`, both optional — see
  "Per-conversation provider/model" below). `sortedMessages` and `preview`
  are computed conveniences used by the UI.
- **`Message`** — id, role (`system` / `user` / `assistant`, stored as a raw
  string for SwiftData compatibility), content, timestamp, and a back-link
  to its conversation.

Both models are plain `@Model` classes wired into a single `ModelContainer`
created once in `AIChatApp.swift` and injected via `.modelContainer(...)`.
There is currently no migration plan defined; schema changes will need a
`SchemaMigrationPlan` once the model shape changes in a shipped version.
`baseURLOverride`/`modelNameOverride` were added as optional properties
specifically so existing rows lightweight-migrate to `nil` (meaning
"inherit the global default", preserving old behavior) with no explicit
migration code needed.

### Settings (`ChatSettings`)

`ChatSettings` is an `@Observable` singleton (`.shared`) that mirrors
non-secret settings (base URL, model name, system prompt, temperature,
theme) to `UserDefaults`, and delegates the API key to `KeychainStore`.
Temperature is loaded via `object(forKey:)` rather than `double(forKey:)`
so an explicitly saved `0.0` is not mistaken for "never set" and replaced
with the `0.7` default on relaunch. It exposes:

- `detectedPreset` — infers which `ProviderPreset` matches the current base
  URL by exact string match, defaulting to `.custom`. This is best-effort;
  editing the base URL to a value not equal to a preset's default (e.g.
  adding a trailing slash) will show as "Custom" even if it's really OpenAI.
- `hasAPIKey` / `apiKey` — reads through to the Keychain on every access
  (no in-memory caching), and are scoped to the *currently active* base URL
  (see below) so they always reflect the right provider's key.

`ProviderPreset` is a static enum of known providers with their default
base URL, default model, suggested models list, and an `allowsEmptyKey`
flag for providers that don't require auth (Apple Intelligence, Ollama,
custom). The `.appleIntelligence` case is the odd one out: it isn't an HTTP
endpoint, so its `defaultBaseURL` is a sentinel string
(`apple-intelligence://on-device`) that can never collide with a real URL.
That keeps `detect(from:)`, per-conversation overrides, and per-provider
model memory working unchanged, while `ProviderPreset.isOnDevice` tells the
UI and the send loop to route generation to `AppleIntelligenceService`
instead of `ChatService`.

#### Multi-provider API keys and models

Each provider gets its own independently-stored API key and remembered
model, keyed by a normalized form of its base URL (trailing slashes and
surrounding whitespace stripped):

- **Keys**: `KeychainStore` accounts are named `"api-key::<normalized base
  URL>"` rather than a single shared `"api-key"` account, so saving a key
  for Anthropic doesn't touch or get overwritten by OpenAI's key.
  `ChatSettings.apiKey(forBaseURL:)` / `hasAPIKey(forBaseURL:)` let callers
  check an arbitrary provider's key without switching to it first.
- **Models**: `ChatSettings.modelsByProvider` (a `[String: String]`
  dictionary in `UserDefaults`, keyed the same way as the Keychain accounts)
  remembers the last model used with each base URL. `applyPreset(_:)` is the
  entry point both `SettingsView` and `ModelProviderPickerSheet` use to
  switch providers: it sets the base URL, then restores the remembered
  model for that URL if one exists, falling back to the preset's
  `defaultModel` otherwise.
- **Migration**: on first launch after this change, any key found under the
  old single shared `"api-key"` Keychain account is copied to the
  currently-active provider's scoped account and the legacy entry is
  deleted (`migrateLegacyAPIKeyIfNeeded()`), so upgrading users don't lose
  a previously-saved key.

Note this scoping is per base URL, not per `ProviderPreset` case — two
different custom endpoints are treated as two different "providers" for
key/model storage purposes, which is the intended behavior (they're
different services), but means renaming/retyping a custom base URL will
appear to "lose" its key/model (they're still in storage under the old URL
string, just not looked up anymore).

#### Per-conversation provider/model

Each `Conversation` can independently override which provider/model it
sends requests to, via `baseURLOverride` / `modelNameOverride`
(`Conversation.swift`). The override is optional and the fallback chain is:

1. If both are set, `Conversation.effectiveBaseURL` /
   `effectiveModelName` use them directly.
2. If `nil` (the default for rows that predate this feature, and
   momentarily during a `Conversation`'s own `init` before it snapshots —
   see below), they fall back live to `ChatSettings.shared`, exactly
   matching the old single-global-setting behavior.

New conversations snapshot the *current* global default into their
override at creation time (`Conversation.init`), so a later change to the
global default in Settings does not retroactively change conversations
that already exist — each conversation's provider/model is stable once
created, the same way its message history is. Pre-existing conversations
(created before this feature, with `nil` overrides) are the one case that
keeps tracking the live global default indefinitely, until the user
explicitly picks a model for them.

`Conversation.setProviderOverride(baseURL:model:)` is the only way to
change an existing conversation's override; it sets both fields together
so a conversation can't end up with, say, an OpenAI base URL and an
Anthropic model name. `ChatDetailView`'s `ModelProviderPickerSheet` calls
this when the user picks a provider/model for a specific conversation, and
also calls `ChatSettings.rememberModel(_:forBaseURL:)` so that choice is
remembered at the provider level too (i.e. it becomes the default the next
*new* conversation with that provider will start with, matching
`applyPreset(_:)`'s per-provider model memory in `SettingsView`).

`ChatService.streamCompletion` and `fetchModels` both take an explicit
`baseURL`/`model` (rather than always reading `settings.baseURLString` /
`settings.modelName`), so a conversation can stream against its own
override without mutating — or racing against concurrent mutation of —
the global `ChatSettings.shared` singleton.

### Networking (`ChatService`)

`ChatService` builds a `POST {baseURL}/chat/completions` request with
`stream: true`, using `URLSession.bytes(for:)` to consume the response as
an async line sequence. It expects Server-Sent Events framing (`data: ...`
lines, terminated by `data: [DONE]`), and decodes each JSON payload's
`choices[0].delta.content` into the `onToken` callback. `onToken` is
`@MainActor`-isolated, so although the SSE loop itself runs off the main
actor, tokens are always delivered on it and callers can update view state
directly. Cancelling the surrounding task (the chat view's stop button)
aborts the stream and propagates `CancellationError`/`URLError.cancelled`,
which the view treats as "stopped by user" rather than a failure.

Error handling:
- Missing API key when the preset requires one → `.missingAPIKey` before
  any network call is made.
- Invalid base URL string → `.invalidURL`.
- Non-2xx HTTP status → `.http(code, body)`, where `body` is a best-effort
  read of up to ~4000 characters of the response.
- Any other framing/decoding issue is silently skipped per-line (malformed
  or unrecognized SSE lines don't abort the stream) rather than surfaced as
  `.stream(...)`. This favors resilience across differing provider
  implementations over strict protocol conformance.

`ChatService` holds no per-request state; a new instance is safe to create
per call (see `ChatDetailView`, which holds one instance for its lifetime).

`ChatService.fetchModels()` calls `GET {baseURL}/models` (the standard
OpenAI-compatible models-list endpoint) and decodes `{ "data": [{ "id": ... }] }`
into `[ProviderModel]`, sorted alphabetically. It shares the same auth and
error-handling conventions as `streamCompletion` (missing-key check,
invalid-URL check, `.http` on non-2xx). `SettingsView` uses this to let the
user fetch and pick from the live list of models their configured provider
actually supports, instead of relying solely on the static
`suggestedModels` per preset.

### On-device generation (`AppleIntelligenceService`)

`AppleIntelligenceService` is the on-device counterpart to `ChatService`,
built on the Foundation Models framework (`SystemLanguageModel` /
`LanguageModelSession`, iOS 26+). It mirrors the same streaming contract —
full history in, token deltas delivered on the main actor — so
`ChatDetailView`'s send loop, throttling, stop button, and error handling
work identically for both provider kinds.

Key design points:

- **Stateless like the HTTP path.** The framework's
  `LanguageModelSession` normally accumulates its own context, but this
  app owns the conversation history (SwiftData) and resends it every turn
  — so each call builds a *fresh* session seeded with a `Transcript`
  replayed from the message list (`makeTranscript(from:)`): system prompt
  → `.instructions`, user → `.prompt`, assistant → `.response`, and the
  trailing user message becomes the actual prompt. This keeps retry /
  regenerate / per-conversation provider switching consistent with the
  HTTP providers, at the cost of re-ingesting history each turn.
- **Streaming**: `session.streamResponse(to:options:)` yields cumulative
  snapshots; the service diffs each snapshot against the previous one and
  forwards only the new suffix to `onToken`, so callers can append exactly
  like they do for SSE chunks.
- **Availability**: `SystemLanguageModel.default.availability` maps to the
  `AppleIntelligenceStatus` enum (`.available` / device not eligible /
  Apple Intelligence not enabled / model still downloading). Settings and
  the per-conversation picker show this instead of the API-key / model
  controls, and streaming throws a descriptive error if the model isn't
  usable. The status read is observation-tracked, so those rows update
  live when a model download finishes.
- **Temperature**: passed through to `GenerationOptions(temperature:)`, so
  the same Settings slider applies (no model-name gating needed — there's
  exactly one on-device model).
- **Context window**: the on-device model has a ~4k-token context.
  `GenerationError.exceededContextWindowSize` is mapped to a friendly
  "conversation too long" error suggesting a new chat or a cloud provider.
- No entitlement, no network permission, and no API key are required.

### Secure storage (`KeychainStore`)

A minimal wrapper around the Keychain Services API (`SecItemAdd` /
`SecItemUpdate` / `SecItemCopyMatching` / `SecItemDelete`) scoped to a
single service identifier (`com.robert.parley.byok` — renamed from the
original `com.demo-app.byok` before the first release; keep it stable from
now on, since renaming orphans saved keys). Only the API key is
stored here; everything else lives in `UserDefaults` via `ChatSettings`.
Accessibility is `kSecAttrAccessibleAfterFirstUnlock`, so the app can send
requests in the background (e.g. from a Live Activity or notification
extension) after first unlock without requiring the device to be unlocked
again.

### UI layer

- **`ContentView`** — `NavigationSplitView` sidebar of conversations
  (via `@Query`), with new/delete actions and two layers of first-run
  gating. First, the age gate: until a passing birth year is declared,
  `AgeGateView` is presented as a non-dismissable `fullScreenCover`.
  Second, onboarding: if the active provider *requires* a key and none is
  set, `SettingsView` is presented automatically (keyless providers —
  Apple Intelligence, Ollama, custom — don't trigger this). The Settings
  sheet only presents once the age gate has passed
  (`maybeShowFirstRunSettings()`, re-checked via `onChange` of the
  declared birth year), so the two never compete for the same
  presentation slot.
- **`AgeGateView` / `AgeGate`** — declared-age gate required by App
  Review Guideline 4.7.5 (the app renders unfiltered model output, rated
  17+). `AgeGate` (`Settings/AgeGate.swift`) is a `nonisolated` enum
  holding the pure policy — minimum age, UserDefaults key
  (`ageGate.declaredBirthYear`, `0` = undeclared), `passes(birthYear:now:)`,
  and the selectable year range — so it's unit-testable with injected
  dates. `AgeGateView` shows a birth-year wheel on first launch; a
  passing year dismisses the cover (the binding reads the `@AppStorage`
  value), while an under-17 declaration switches to a persistent blocked
  screen with no way to re-enter a different year. Only the year is
  collected, stored only on-device.
- **`ChatDetailView`** — owns the send/stream loop. On send, it appends a
  user `Message`, saves, then starts a cancellable `Task` that branches on
  the conversation's preset: HTTP providers go to
  `ChatService.streamCompletion` with the conversation's own
  `effectiveBaseURL`/`effectiveModelName`; the on-device preset goes to
  `AppleIntelligenceService.streamCompletion`. Both deliver tokens the same
  way: into a private `@Observable StreamBuffer` that flushes into view
  state at most ~15×/s (rather than per token), so a fast stream doesn't
  force a full view re-render — and a re-sort of the message list — on
  every chunk. A final `flush()` on completion/cancel guarantees no
  trailing tokens are lost. The streaming text is rendered as a separate
  "streaming bubble" while in flight, then committed as an assistant
  `Message` on success, as an inline ⚠️ error message on failure, or as a
  partial reply (no alert) if the user taps stop. The send button becomes a
  stop button while streaming. The navigation-bar title area shows this
  conversation's active provider/model and is tappable to open
  `ModelProviderPickerSheet` — a scoped version of the provider/model
   pickers from `SettingsView`, but editing the conversation's own override
   (see "Per-conversation provider/model" above) rather than the global
   default. For the on-device preset the sheet hides the model controls and
   shows the device's Apple Intelligence availability instead. It also owns a
   `VoiceInputSession` for live on-device dictation. The view snapshots the
   typed draft before recording, combines it with partial/final transcripts,
   restores it on cancellation, and prevents sending or response streaming
   while voice input is active.
- **`SettingsView`** — provider preset picker (drives base URL + model
  defaults), base URL/model/system prompt/temperature editors, the
  API key save/remove flow, a "Fetch available models" action that
  calls `ChatService.fetchModels()` and surfaces the result as a picker,
   and an appearance section for choosing the app theme.

### On-device voice input (`VoiceInputSession`)

`VoiceInputSession` is the chat composer's seam over Apple's Speech and
AVFAudio frameworks. Its small observable interface exposes `state`, the
current utterance `transcript`, and `start()` / `finish()` / `cancel()`.
Internally it owns the complete microphone lifecycle:

- Requests microphone permission and resolves a locale equivalent to the
  device's current locale through `SpeechTranscriber` runtime checks.
- Uses `AssetInventory` to install and reserve the Apple-managed locale model,
  publishing download progress through the preparation state. The model may
  need a network download, but recognition runs entirely on device.
- Configures `AVAudioSession` / `AVAudioEngine`, converts microphone buffers to
  the exact format required by `SpeechAnalyzer`, and streams `AnalyzerInput`
  values into the analyzer.
- Replaces volatile hypotheses while appending final results exactly once, so
  the composer gets low-latency text without duplicated words.
- Gracefully finalizes on the user's stop action to preserve trailing words.
  Cancellation, setup failure, interruption, route loss, scene deactivation,
  conversation changes, and view disappearance all share idempotent cleanup of
  the tap, engine, analyzer, tasks, and audio session.

The audio itself is never persisted, logged, attached to SwiftData, or sent to
a provider. After transcription, the editable text follows the normal send
path: cloud providers receive it only when the user taps Send, while the Apple
Intelligence provider keeps the complete flow local.

### Web search (`WebResearchService`)

`WebResearchService` adds optional, one-turn web grounding without changing the
selected model provider's request protocol. When the composer globe control is
enabled, the current user message is sent to Brave Search's LLM Context endpoint
using a user-owned key stored by `WebSearchSettings` in Keychain. The service
limits the query, request budget, snippets, prompt context, and source count;
rejects unsafe source URLs; and returns temporary untrusted evidence plus an
app-owned source allowlist.

`ChatDetailView` runs retrieval and generation under the same cancellable task.
It appends the evidence only to the transient trailing provider message along
with an instruction to cite `[source:N]`; it never stores raw excerpts in chat
history. On success or partial cancellation, the assistant `Message` stores a
small JSON source payload (ID, title, HTTPS URL, domain), which renders as a
trusted Sources row. Search-stage failures remain transient errors instead of
creating an ungrounded answer. This works identically with Apple Intelligence,
HTTP providers, Ollama, and custom OpenAI-compatible endpoints because every
generation path receives ordinary text messages after retrieval.

### Appearance (`AppTheme`)

`ChatSettings.theme` stores an `AppTheme` (`.system` / `.light` / `.dark`),
mirrored to `UserDefaults` like the other non-secret settings.
`AIChatApp` reads it and applies `.preferredColorScheme(settings.theme.colorScheme)`
at the `WindowGroup` root, so the whole app (all sheets included) follows
the chosen theme; `.system` maps to `nil`, which defers to the OS-level
appearance setting. `SettingsView` exposes it as a segmented picker in the
"Appearance" section.

### Retry / regenerate

`ChatDetailView` factors the send flow into `startStreaming()`, called both
by `send()` (after appending a new user message) and by
`regenerate(from:inclusive:)`. The latter is used for two context-menu
actions on `MessageBubble`:

- **Retry** (on a user message) — deletes everything *after* that message
  (typically a failed or unwanted assistant reply) and re-requests a
  completion using the same history up to and including that user message.
  If the message is already the last one, there is nothing to delete and it
  simply re-requests a response.
- **Regenerate** (on an assistant message, also shown as a small inline
  button under the most recent assistant reply) — deletes that message and
  everything after it, then re-requests a completion.

Both delete the trailing `Message`s from the `Conversation` and the
`ModelContext`, then call `startStreaming()` to fetch a fresh response.
This mutates conversation history rather than branching it — there is no
support for keeping multiple alternate replies ("regenerate and compare")
side by side.

## Data flow: sending a message

1. User types in `ChatInputBar` and taps send.
2. `ChatDetailView.send()` trims input, appends a `user` `Message` to the
   conversation, persists via `modelContext.save()`.
3. A `Task` builds the full provider message list (system prompt + all
   non-system messages in chronological order) and calls either
   `ChatService.streamCompletion` (HTTP providers) or
   `AppleIntelligenceService.streamCompletion` (on-device preset), chosen
   by `ProviderPreset.detect(from: conversation.effectiveBaseURL)`.
4. Each streamed token is appended to the `StreamBuffer`, which re-renders
   the `StreamingBubble` in real time (throttled to ~15 updates/s; a final
   `flush()` on completion guarantees no trailing tokens are lost).
5. On stream completion, the accumulated text becomes an `assistant`
   `Message`, appended and persisted. On failure, an error `Message`
   (prefixed with ⚠️) is appended instead, and an alert is shown. On
   cancellation (stop button), whatever text had arrived is persisted as a
   partial reply with no alert.

Note the full message history is resent on every turn (no server-side
session/thread state) — this is standard for stateless chat completion
APIs, and the on-device path mirrors it by replaying a `Transcript` into a
fresh `LanguageModelSession` each call. Token costs grow with conversation
length for HTTP providers, and the on-device model hard-fails past its
~4k-token context window. There is no truncation/summarization strategy in
place yet.

## Data flow: dictating a message

1. The user taps the microphone in `ChatInputBar`; `ChatDetailView` snapshots
   the current typed draft and calls `VoiceInputSession.start()`.
2. The session requests permission, resolves/installs the current locale's
   model, activates the microphone, and starts `SpeechAnalyzer` with a
   `SpeechTranscriber` module.
3. Partial and final results update `VoiceInputSession.transcript`; the view
   combines that utterance with the original typed draft in the composer.
4. The user taps the red stop button. The session stops capture, finishes its
   input stream, finalizes through the end of audio, then releases resources.
5. Final text remains an editable draft. Nothing is persisted or transmitted
   until the existing Send action creates a user `Message`.

## Data flow: web-grounded message

1. The user enables the composer globe control and taps Send. The resulting
   user `Message` is marked as having requested web search, then the control
   resets.
2. `ChatDetailView` asks `WebResearchService` for bounded Brave LLM Context
   evidence using the current user message only.
3. The temporary evidence block and source-ID instruction are appended to the
   trailing provider message, then the normal Apple Intelligence or HTTP stream
   begins.
4. On completion or partial cancellation, the assistant message persists only
   source metadata. The UI renders those allowlisted links below its response.

## Known gaps / suggested next steps

- **Test coverage**: `ParleyTests` covers `ChatSettings` temperature
  persistence (including the 0.0-survives-relaunch case), the `AgeGate`
  policy (pass/block boundaries at 17, undeclared state, year range),
  plus (currently
  disabled — see `f83524d`) per-provider API key isolation,
  model-per-provider recall via `applyPreset(_:)`, legacy shared-key
  migration, `ProviderPreset.detect`, and `Conversation`'s
  per-conversation override/fallback semantics. Still missing:
  `ChatService` SSE parsing (given canned byte streams) and
  `KeychainStore` round-trip save/read/delete in isolation.
- **Schema migration**: no `VersionedSchema`/`SchemaMigrationPlan` exists
  yet for `Conversation`/`Message`; add one before the first schema change
  ships to users with existing data.
- **Context length management**: long conversations are resent in full on
  every turn with no truncation or summarization. This bites the on-device
  model first (~4k-token context — the stream fails with a "conversation
  too long" error), but every provider has a limit.
- **Custom base URL key/model "loss" on retyping**: keys and remembered
  models for the `.custom` preset are scoped to the exact base URL string.
  Editing a custom base URL (even fixing a typo) is indistinguishable from
  switching to a new provider, so the previously-saved key/model for the
  old string appears to disappear (it's still in storage, just orphaned).
- **No reply branching**: retry/regenerate overwrite history in place
  (deleting the discarded messages) rather than keeping alternates. A
  tree-structured message model would be needed to support comparing
  multiple regenerated replies.

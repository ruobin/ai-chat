# Architecture

## Overview

demo-app is a single-target SwiftUI iOS app. It has no backend of its own —
it's a thin client that speaks the OpenAI `chat/completions` HTTP API
(streaming, via SSE) to whichever provider the user configures. Local state
(conversations, messages) is persisted with SwiftData; the API key is
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
      ┌───────────────────┐
      │   ChatService       │
      │   (streaming HTTP   │──────▶  Provider API (OpenAI, Anthropic,
      │    client)           │         Google, DeepSeek, xAI, OpenRouter,
      └───────────────────┘         Ollama, or any custom OpenAI-compatible
                                      endpoint)
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
created once in `demo_appApp.swift` and injected via `.modelContainer(...)`.
There is currently no migration plan defined; schema changes will need a
`SchemaMigrationPlan` once the model shape changes in a shipped version.
`baseURLOverride`/`modelNameOverride` were added as optional properties
specifically so existing rows lightweight-migrate to `nil` (meaning
"inherit the global default", preserving old behavior) with no explicit
migration code needed.

### Settings (`ChatSettings`)

`ChatSettings` is an `@Observable` singleton (`.shared`) that mirrors
non-secret settings (base URL, model name, system prompt, temperature) to
`UserDefaults`, and delegates the API key to `KeychainStore`. It exposes:

- `detectedPreset` — infers which `ProviderPreset` matches the current base
  URL by exact string match, defaulting to `.custom`. This is best-effort;
  editing the base URL to a value not equal to a preset's default (e.g.
  adding a trailing slash) will show as "Custom" even if it's really OpenAI.
- `hasAPIKey` / `apiKey` — reads through to the Keychain on every access
  (no in-memory caching), and are scoped to the *currently active* base URL
  (see below) so they always reflect the right provider's key.

`ProviderPreset` is a static enum of known providers with their default
base URL, default model, suggested models list, and an `allowsEmptyKey`
flag for providers that don't require auth (Ollama, custom).

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
`choices[0].delta.content` into the `onToken` callback.

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

### Secure storage (`KeychainStore`)

A minimal wrapper around the Keychain Services API (`SecItemAdd` /
`SecItemUpdate` / `SecItemCopyMatching` / `SecItemDelete`) scoped to a
single service identifier (`com.demo-app.byok`). Only the API key is
stored here; everything else lives in `UserDefaults` via `ChatSettings`.
Accessibility is `kSecAttrAccessibleAfterFirstUnlock`, so the app can send
requests in the background (e.g. from a Live Activity or notification
extension) after first unlock without requiring the device to be unlocked
again.

### UI layer

- **`ContentView`** — `NavigationSplitView` sidebar of conversations
  (via `@Query`), with new/delete actions and gating: if no API key is set,
  `SettingsView` is presented automatically on first appearance.
- **`ChatDetailView`** — owns the send/stream loop. On send, it appends a
  user `Message`, saves, then starts a `Task` that calls
  `ChatService.streamCompletion` with the conversation's own
  `effectiveBaseURL`/`effectiveModelName`, appending tokens to a local
  `streamingContent` buffer (rendered as a separate "streaming bubble" while
  in flight) before committing the final text as an assistant `Message` on
  completion or as an inline error message on failure. The navigation bar
  title area shows this conversation's active provider/model and is
  tappable to open `ModelProviderPickerSheet` — a scoped version of the
  provider/model pickers from `SettingsView`, but editing the
  conversation's own override (see "Per-conversation provider/model"
  above) rather than the global default.
- **`SettingsView`** — provider preset picker (drives base URL + model
  defaults), base URL/model/system prompt/temperature editors, the
  API key save/remove flow, a "Fetch available models" action that
  calls `ChatService.fetchModels()` and surfaces the result as a picker,
  and an appearance section for choosing the app theme.

### Appearance (`AppTheme`)

`ChatSettings.theme` stores an `AppTheme` (`.system` / `.light` / `.dark`),
mirrored to `UserDefaults` like the other non-secret settings.
`demo_appApp` reads it and applies `.preferredColorScheme(settings.theme.colorScheme)`
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
   non-system messages in chronological order) and calls
   `ChatService.streamCompletion`.
4. Each streamed token is appended to `streamingContent`, which re-renders
   the `StreamingBubble` in real time.
5. On stream completion, the accumulated text becomes an `assistant`
   `Message`, appended and persisted. On failure, an error `Message`
   (prefixed with ⚠️) is appended instead, and an alert is shown.

Note the full message history is resent on every turn (no server-side
session/thread state) — this is standard for stateless chat completion
APIs, but means token costs grow with conversation length. There is no
truncation/summarization strategy in place yet.

## Known gaps / suggested next steps

- **Test coverage**: `demo-appTests` now covers `ChatSettings`'
  per-provider API key isolation, model-per-provider recall via
  `applyPreset(_:)`, legacy shared-key migration, `ProviderPreset.detect`,
  and `Conversation`'s per-conversation override/fallback semantics. Still
  missing: `ChatService` SSE parsing (given canned byte streams) and
  `KeychainStore` round-trip save/read/delete in isolation.
- **Schema migration**: no `VersionedSchema`/`SchemaMigrationPlan` exists
  yet for `Conversation`/`Message`; add one before the first schema change
  ships to users with existing data.
- **Context length management**: long conversations are resent in full on
  every request with no truncation or summarization.
- **Custom base URL key/model "loss" on retyping**: keys and remembered
  models for the `.custom` preset are scoped to the exact base URL string.
  Editing a custom base URL (even fixing a typo) is indistinguishable from
  switching to a new provider, so the previously-saved key/model for the
  old string appears to disappear (it's still in storage, just orphaned).
- **No reply branching**: retry/regenerate overwrite history in place
  (deleting the discarded messages) rather than keeping alternates. A
  tree-structured message model would be needed to support comparing
  multiple regenerated replies.

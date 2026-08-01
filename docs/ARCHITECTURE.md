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
      │   (streaming HTTP   │──────▶  Provider API (OpenAI, DeepSeek,
      │    client)           │         xAI, Groq, OpenRouter, Ollama,
      └───────────────────┘         or any custom OpenAI-compatible
                                      endpoint)
```

## Components

### Data layer (SwiftData)

- **`Conversation`** — id, title, timestamps, and a `@Relationship` to its
  `Message`s with cascade delete. `sortedMessages` and `preview` are
  computed conveniences used by the UI.
- **`Message`** — id, role (`system` / `user` / `assistant`, stored as a raw
  string for SwiftData compatibility), content, timestamp, and a back-link
  to its conversation.

Both models are plain `@Model` classes wired into a single `ModelContainer`
created once in `demo_appApp.swift` and injected via `.modelContainer(...)`.
There is currently no migration plan defined; schema changes will need a
`SchemaMigrationPlan` once the model shape changes in a shipped version.

### Settings (`ChatSettings`)

`ChatSettings` is an `@Observable` singleton (`.shared`) that mirrors
non-secret settings (base URL, model name, system prompt, temperature) to
`UserDefaults`, and delegates the API key to `KeychainStore`. It exposes:

- `detectedPreset` — infers which `ProviderPreset` matches the current base
  URL by exact string match, defaulting to `.custom`. This is best-effort;
  editing the base URL to a value not equal to a preset's default (e.g.
  adding a trailing slash) will show as "Custom" even if it's really OpenAI.
- `hasAPIKey` / `apiKey` — reads through to the Keychain on every access
  (no in-memory caching), so it always reflects the current Keychain state.

`ProviderPreset` is a static enum of known providers with their default
base URL, default model, suggested models list, and an `allowsEmptyKey`
flag for providers that don't require auth (Ollama, custom).

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
  `ChatService.streamCompletion`, appending tokens to a local
  `streamingContent` buffer (rendered as a separate "streaming bubble" while
  in flight) before committing the final text as an assistant `Message` on
  completion or as an inline error message on failure.
- **`SettingsView`** — provider preset picker (drives base URL + model
  defaults), base URL/model/system prompt/temperature editors, the
  API key save/remove flow, and a "Fetch available models" action that
  calls `ChatService.fetchModels()` and surfaces the result as a picker.

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

- **Test coverage**: `demo-appTests` is currently an empty stub. Priority
  candidates for unit tests: `ChatService` SSE parsing (given canned byte
  streams), `ChatSettings.detectedPreset` matching, and `KeychainStore`
  round-trip save/read/delete.
- **Schema migration**: no `VersionedSchema`/`SchemaMigrationPlan` exists
  yet for `Conversation`/`Message`; add one before the first schema change
  ships to users with existing data.
- **Context length management**: long conversations are resent in full on
  every request with no truncation or summarization.
- **Entitlements cleanup**: `demo_app.entitlements` declares
  `aps-environment` and a CloudKit container, neither of which is
  referenced by any code path today.

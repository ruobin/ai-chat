# AI Chat

A SwiftUI chat client for iOS that talks to any OpenAI-compatible chat
completions API. Bring your own key (BYOK): pick a provider preset or point
it at a custom endpoint, paste in an API key (or skip it for local servers),
and start chatting. Conversations are persisted locally with SwiftData.

The app displays as **AI Chat** on the home screen (`CFBundleDisplayName`);
the underlying Xcode project, target, and scheme are still named `demo-app`
throughout this repo and its tooling (see below).

## Features

- Streaming responses via Server-Sent Events (`/chat/completions` with
  `stream: true`), with a stop button that keeps the partial reply
- Presets for OpenAI, Anthropic (Claude), Google (Gemini), DeepSeek,
  xAI (Grok), and OpenRouter, plus local Ollama and a custom endpoint
  option for anything OpenAI-compatible (vLLM, LM Studio, Together, etc.)
- Fetch the live list of models from your configured provider
  (`GET /models`) and pick one directly in Settings
- Switch provider and model right from the chat page toolbar, without
  leaving the conversation (per-conversation override)
- Retry / regenerate from a message's context menu
- API keys stored in the iOS Keychain, never in `UserDefaults` or logs
- Local conversation history via SwiftData, with swipe-to-delete
- Configurable system prompt, temperature, and light/dark/system theme

## Requirements

- Xcode 16+
- iOS 18+ (uses the `@Observable` macro and SwiftData)

## Getting started

1. Open `demo-app.xcodeproj` in Xcode.
2. Build and run the `demo-app` scheme on a simulator or device.
3. On first launch you'll be prompted for Settings — pick a provider preset,
   paste an API key (skip this for Ollama/local), and choose a model.
4. Start a new chat from the pencil icon in the sidebar.

No API key ships with the app. You must supply your own from your chosen
provider.

## Project layout

```
demo-app/
  demo_appApp.swift      App entry point, SwiftData ModelContainer setup
  ContentView.swift       Sidebar + navigation split view, conversation list
  ChatDetailView.swift    Message list, throttled streaming bubble, input bar
  SettingsView.swift      Provider/model/API key/system prompt/temperature UI
  ChatService.swift       OpenAI-compatible streaming HTTP client
  ChatSettings.swift      Observable settings store + provider presets
  Conversation.swift      SwiftData model (incl. per-conversation provider)
  Message.swift           SwiftData model
  KeychainStore.swift     Keychain read/write/delete wrapper for the API key
demo-appTests/            Unit test target (Swift Testing)
demo-appUITests/          UI test target (XCTest)
docs/
  ARCHITECTURE.md         Component map, data flow, known gaps
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a deeper look at how
the pieces fit together.

## Testing

Run tests from Xcode (`Cmd+U`) or:

```sh
xcodebuild test -project demo-app.xcodeproj -scheme demo-app \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

`demo-appTests` covers `ChatSettings` temperature persistence and (currently
disabled — see commit history) per-provider key/model scoping,
`ProviderPreset.detect`, and per-conversation provider overrides. See
`docs/ARCHITECTURE.md` for remaining coverage gaps.

## Security notes

- API keys are stored in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`)
  under service `com.demo-app.byok`, scoped per provider base URL.
- Keys are sent only as the `Authorization: Bearer <key>` header on requests
  to the base URL you configure. No key is logged or transmitted elsewhere.
- Local/custom providers (Ollama, custom endpoints) are allowed to run with
  no key at all.

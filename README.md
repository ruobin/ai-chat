# demo-app

A SwiftUI chat client for iOS that talks to any OpenAI-compatible chat
completions API. Bring your own key (BYOK): pick a provider preset or point
it at a custom endpoint, paste in an API key (or skip it for local servers),
and start chatting. Conversations are persisted locally with SwiftData.

## Features

- Streaming responses via Server-Sent Events (`/chat/completions` with
  `stream: true`)
- Presets for OpenAI, DeepSeek, xAI (Grok), Groq, OpenRouter, and local
  Ollama, plus a custom endpoint option for anything OpenAI-compatible
  (vLLM, LM Studio, Together, etc.)
- Fetch the live list of models from your configured provider
  (`GET /models`) and pick one directly in Settings
- API keys stored in the iOS Keychain, never in `UserDefaults` or logs
- Local conversation history via SwiftData, with swipe-to-delete
- Configurable system prompt and temperature per install

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
  ChatDetailView.swift    Message list, streaming bubble, input bar
  SettingsView.swift      Provider/model/API key/system prompt/temperature UI
  ChatService.swift       OpenAI-compatible streaming HTTP client
  ChatSettings.swift      Observable settings store + provider presets
  Conversation.swift      SwiftData model
  Message.swift           SwiftData model
  KeychainStore.swift     Keychain read/write/delete wrapper for the API key
demo-appTests/            Unit test target (Swift Testing)
demo-appUITests/          UI test target (XCTest)
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a deeper look at how
the pieces fit together.

## Testing

Run tests from Xcode (`Cmd+U`) or:

```sh
xcodebuild test -project demo-app.xcodeproj -scheme demo-app \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Note: the current test target is a stub; see `docs/ARCHITECTURE.md` for
suggested coverage.

## Security notes

- API keys are stored in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`)
  under service `com.demo-app.byok`, keyed per setting name.
- Keys are sent only as the `Authorization: Bearer <key>` header on requests
  to the base URL you configure. No key is logged or transmitted elsewhere.
- Local/custom providers (Ollama, custom endpoints) are allowed to run with
  no key at all.

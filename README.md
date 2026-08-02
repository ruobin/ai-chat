# AI Chat

A SwiftUI chat client for iOS that talks to Apple Intelligence's on-device
model or any OpenAI-compatible chat completions API. Use it zero-config with
the built-in on-device model, or bring your own key (BYOK): pick a provider
preset or point it at a custom endpoint, paste in an API key (or skip it for
local servers), and start chatting. Conversations are persisted locally with
SwiftData.

The app displays as **AI Chat** on the home screen (`CFBundleDisplayName`),
and the Xcode project, target, and scheme are all named `ai-chat`. The bundle
identifier is deliberately still `com.robert.demo-app`, so existing installs
keep upgrading in place instead of being orphaned.

## Features

- **Apple Intelligence on-device provider** — chat with the built-in
  ~3B-parameter local model via the Foundation Models framework. No API key,
  no network, fully private. Requires an Apple Intelligence–capable device
- **On-device voice input** — dictate an editable message draft from the chat
  composer via Apple's Speech framework. Live audio is transcribed locally and
  is never saved or uploaded
- **Web search for every model** — enable Brave Search for one message to ground
  Apple Intelligence, cloud, Ollama, or custom-model answers with clickable
  source links. Requires your own Brave Search API key
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

- Xcode 26+ (the app links the Foundation Models framework, iOS 26 SDK)
- iOS 26+ (deployment target 26.5)
- The Apple Intelligence provider additionally requires a device that
  supports Apple Intelligence, with Apple Intelligence enabled and the
  on-device model downloaded. All other providers work on any device.
- Voice input requires a device and current language supported by Apple's
  `SpeechTranscriber`. First use may download an Apple-managed language model;
  test recognition on a physical device rather than relying on Simulator.

## Getting started

1. Open `ai-chat.xcodeproj` in Xcode.
2. Build and run the `ai-chat` scheme on a simulator or device.
3. Zero-config option: in Settings, pick the **Apple Intelligence** preset —
   no key needed on a capable device. Otherwise pick a provider preset,
   paste an API key (skip this for Ollama/local), and choose a model.
4. Start a new chat from the pencil icon in the sidebar.

No API key ships with the app. You must supply your own from your chosen
provider (except Apple Intelligence, which needs none).

## Project layout

```
ai-chat/
  App/
    AIChatApp.swift     App entry point, SwiftData ModelContainer setup
  Models/
    Conversation.swift    SwiftData model (incl. per-conversation provider)
    Message.swift         SwiftData model
  Services/
    ChatService.swift     OpenAI-compatible streaming HTTP client
    AppleIntelligenceService.swift  On-device model via Foundation Models
    VoiceInputSession.swift         Live on-device speech capture
    WebResearchService.swift        Brave retrieval, limits, source validation
    KeychainStore.swift   Keychain read/write/delete wrapper for API keys
  Settings/
    ChatSettings.swift    Observable settings store + provider presets
    WebSearchSettings.swift  Brave key and disclosure preference storage
  Views/
    ContentView.swift     Sidebar + navigation split view, conversation list
    ChatDetailView.swift  Message list, throttled streaming bubble, input bar
    SettingsView.swift    Provider/model/key/system prompt/temperature UI
    Markdown/
      MarkdownContent.swift  Markdown block parser, citations, link safety
      MarkdownText.swift     SwiftUI renderer for parsed blocks
  Assets.xcassets, Info.plist, ai-chat.entitlements
ai-chatTests/            Unit test target (Swift Testing)
ai-chatUITests/          UI test target (XCTest)
docs/
  ARCHITECTURE.md         Component map, data flow, known gaps
```

The Xcode target uses a synchronized root group, so these folders are
picked up automatically — adding or moving a `.swift` file under
`ai-chat/` needs no `project.pbxproj` edit.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for a deeper look at how
the pieces fit together.

## Testing

Run tests from Xcode (`Cmd+U`) or:

```sh
xcodebuild test -project ai-chat.xcodeproj -scheme ai-chat \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

`ai-chatTests` covers `ChatSettings` temperature persistence, the Apple
Intelligence preset (sentinel detection, transcript construction), and
(currently disabled — see commit history) per-provider key/model scoping,
`ProviderPreset.detect`, and per-conversation provider overrides. See
`docs/ARCHITECTURE.md` for remaining coverage gaps.

## Security notes

- API keys are stored in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`)
  under service `com.demo-app.byok`, scoped per provider base URL.
- Keys are sent only as the `Authorization: Bearer <key>` header on requests
  to the base URL you configure. No key is logged or transmitted elsewhere.
- The Apple Intelligence provider never touches the network or a key —
  prompts and responses stay on the device (subject to Apple's own
  on-device processing guarantees).
- Voice recordings stay in memory and are transcribed on device. Only the
  resulting editable text follows the selected provider's normal behavior when
  you tap Send; cloud providers receive that text, while Apple Intelligence
  keeps it local.
- Web search sends only the current enabled message to Brave Search. The
  resulting evidence is included in a cloud provider's request, or used locally
  with Apple Intelligence. Raw excerpts are not stored; saved assistant
  messages retain only source title, domain, and URL metadata.
- Local/custom providers (Ollama, custom endpoints) are allowed to run with
  no key at all.

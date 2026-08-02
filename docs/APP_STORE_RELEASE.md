# App Store release checklist

The app ships under the name **Parley**. What has been done in code, and
what only you can do. Guideline numbers refer to the
[App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

Verify guideline text against the live page before submitting — Apple
renumbers sections between revisions.

## Blockers you must clear before archiving

### 1. Fill in `SupportInfo` — required

`ai-chat/Settings/SupportInfo.swift` ships with placeholders. Until they're
replaced:

- the **Support** section in Settings is hidden entirely, and
- the **Report response** action on assistant replies does not appear.

Both are compliance requirements, so the app is **not submittable** in this
state:

| Value | Why | Guideline |
| --- | --- | --- |
| `contactEmail` | Published contact info, and the destination for content reports | 1.5, 4.7.1 |
| `privacyPolicyURL` | Must be reachable in-app *and* entered in App Store Connect | 5.1.1(i) |
| `supportURL` | App Store "Support URL" | 1.5 |

The code deliberately hides these rows rather than shipping a dead `mailto:`
or a 404, either of which is its own rejection risk under 2.1. `SupportInfo.isConfigured`
is the single switch that gates them.

### 2. Write the privacy policy

The app has **no developer backend** — nothing is collected by us. But it does
send data to third parties *at the user's direction*, and Guideline 5.1.2(i)
requires explicit disclosure "where personal data will be shared with third
parties, including with third-party AI". The policy must name:

- Every provider the user can select: OpenAI, Anthropic, Google, DeepSeek,
  xAI, OpenRouter, Ollama (local), and any custom endpoint the user enters.
  Message content goes to whichever one is selected.
- **Brave Search**, when the user arms web search for a message. Only that
  message's text is sent, capped at 50 words / 400 characters with fenced
  code blocks stripped. Brave documents query retention of up to 90 days.
- **Apple Intelligence** sends nothing — generation is fully on-device.
- What stays local: conversations in SwiftData on device, API keys in the
  Keychain (`kSecAttrAccessibleAfterFirstUnlock`, not synced to iCloud).
- Deletion: users delete conversations in-app; deleting the app removes
  everything. There is no server-side copy to request deletion of.

## App Store Connect setup

### Listing copy — ready to paste

**Name:** Parley

**Subtitle (30 chars max):** `Private AI Chat` (15 chars)

**Category:** Productivity (matches `LSApplicationCategoryType`).

**Description:**

> Parley is a private, bring-your-own-key AI chat app.
>
> Talk to Apple's on-device model with no account, no API key, and no
> data leaving your iPhone — or plug in your own key for OpenAI,
> Anthropic, Google, DeepSeek, xAI, OpenRouter, a local Ollama server,
> or any OpenAI-compatible endpoint.
>
> PRIVATE BY DESIGN
> • No account, no sign-up, no tracking, no analytics
> • Conversations stay on your device
> • API keys live in the iOS Keychain and never sync
> • On-device Apple Intelligence works fully offline
>
> BRING YOUR OWN KEY
> • Pay providers directly at cost — no markup, no subscription
> • Switch providers and models per conversation
> • Point at any custom OpenAI-compatible server
>
> DO MORE
> • Arm web search to ground answers in current results
> • Dictate messages with on-device transcription
> • Full Markdown rendering with code blocks
>
> Your keys. Your conversations. Your device.

**Keywords (100 chars max):**
`ai,chat,chatbot,gpt,claude,gemini,llm,private,byok,openai,assistant,ollama,offline`
(83 chars — verify count before pasting.)

**Promotional text (170 chars max):**
> Chat with on-device Apple Intelligence free and offline, or bring
> your own API key for OpenAI, Claude, Gemini and more. No account. No
> tracking. No subscription.

### App Privacy questionnaire

Because there is no developer-operated backend, **"Data is not collected"** is
accurate for our own entity. The bundled `ai-chat/PrivacyInfo.xcprivacy`
matches this: no tracking, no tracking domains, no collected data types, and
a single required-reason declaration for `UserDefaults` (`CA92.1`, app's own
settings). Answer the questionnaire consistently with that file — a mismatch
between the manifest and the questionnaire is a common rejection.

### Age rating — expect scrutiny

The app renders unfiltered output from third-party models and can surface
arbitrary web content, so a 4+ rating is not defensible. Rate it honestly for
"Infrequent/Intense Mature or Suggestive Themes" and expect follow-up.

Guideline **4.7 explicitly covers chatbots**, and 4.7.5 requires a way to
identify content exceeding the age rating plus an age restriction mechanism.
The current build has **no age gate**. If review pushes back, the likely asks
are a declared-age gate on first run and a way to restrict which providers a
minor can reach. This is the largest remaining compliance gap.

### Review notes — write these

Reviewers have no API keys, so say this explicitly:

> Parley defaults to Apple's on-device model (Apple Intelligence), which
> needs no API key or network access — please test on an Apple
> Intelligence–capable device running iOS 26.5+ with Apple Intelligence
> enabled in Settings. To test a cloud provider instead, open Settings →
> Provider, choose one, and paste an API key.
>
> The bundle identifier is `com.robert.demo-app` for legacy reasons: it was
> kept deliberately so existing installs upgrade in place. This is a complete
> production release, not a demo or beta build.
>
> Users supply their own API keys and are billed directly by their chosen
> provider. The app unlocks no features or content in exchange for payment,
> so there is nothing sold through it.

Attach a working API key for a cloud provider if you want that path tested.
Without one, review only covers the on-device path.

**Why the bundle ID note matters:** the literal string "demo-app" in a
shipping identifier invites a Guideline 2.2 question about whether this is a
trial build. Pre-empt it.

## Verify before every upload

- [ ] `SupportInfo.isConfigured` returns true — check Settings shows the
      Support section and a reply's context menu shows "Report response".
- [ ] Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- [ ] Archive with the Release configuration, then run the build once from
      the archive on a real device.
- [ ] First launch on a **clean install** (delete the app first) reaches a
      usable chat with no API key, on an Apple Intelligence device.
- [ ] First launch on a device **without** Apple Intelligence still explains
      itself rather than dead-ending.

## Already handled in code

| Item | Where | Guideline |
| --- | --- | --- |
| Removed unused `remote-notification` background mode | `Info.plist` | 2.5.4 |
| Privacy manifest with `UserDefaults` reason `CA92.1` | `PrivacyInfo.xcprivacy` | 5.1.1 |
| `ITSAppUsesNonExemptEncryption = false` (skips the per-upload export prompt) | `Info.plist` | — |
| No launch crash if the local store can't open — falls back to an in-memory store and says so | `App/AIChatApp.swift` | 2.1 |
| Report action on assistant replies | `Views/ChatDetailView.swift` | 4.7.1 |
| Contact / privacy / support links in Settings | `Views/SettingsView.swift` | 1.5, 5.1.1(i) |
| Defaults to the keyless on-device model on a fresh install | `Settings/ChatSettings.swift` | 2.1 |
| Brave one-time disclosure before any web search | `Views/ChatDetailView.swift` | 5.1.2(i) |
| Model-written links restricted to http/https/mailto | `Views/Markdown/MarkdownContent.swift` | 1.6 |
| App icon: 1024×1024, no alpha, light/dark/tinted | `Assets.xcassets` | — |
| No third-party SDKs, analytics, or telemetry | — | 5.1 |

## Known gaps

Judgement calls, not oversights:

- **No age gate.** See 4.7.5 above. The most likely reason for a rejection.
- **No automated content filtering.** Cloud providers apply their own
  moderation, and Apple Intelligence has on-device guardrails, but a
  self-hosted Ollama or custom endpoint has none, and the app does not filter
  what it renders. Guideline 4.7.1 asks for "a method for filtering
  objectionable material"; we currently rely on the upstream provider's.
- **No user blocking.** 4.7.1 asks for the ability to block abusive users.
  There are no other users — this is a single-player app with no social
  surface — so it is arguably inapplicable. Be ready to make that argument.
- **No schema migration plan.** `docs/ARCHITECTURE.md` notes this. The new
  in-memory fallback stops it from being a launch crash, but add a
  `VersionedSchema` before shipping any model change to users with existing
  data.

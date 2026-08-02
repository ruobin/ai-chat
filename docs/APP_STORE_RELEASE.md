# App Store release checklist

The app ships under the name **Parley**. What has been done in code, and
what only you can do. Guideline numbers refer to the
[App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

Verify guideline text against the live page before submitting — Apple
renumbers sections between revisions.

## Blockers — all cleared in code

### 1. `SupportInfo` — DONE

`ai-chat/Settings/SupportInfo.swift` is filled in:

| Value | Set to | Guideline |
| --- | --- | --- |
| `contactEmail` | `ruobin.wang.us@gmail.com` | 1.5, 4.7.1 |
| `privacyPolicyURL` | `https://dict.ai-dictionary.org/privacy` | 5.1.1(i) |
| `supportURL` | `https://dict.ai-dictionary.org/support` | 5.1.1(i), 1.5 |

`SupportInfo.isConfigured` is now true, so the Support section in Settings
and the Report-response action are visible.

### 2. Privacy policy — WRITTEN, needs hosting

`website/privacy.html` and `website/support.html` are ready to host. They
must be live at **exactly** the URLs above (serve `privacy.html` at
`/privacy`, `support.html` at `/support` on `dict.ai-dictionary.org`)
**before submitting** — App Review follows the in-app links, and a 404 is a
rejection under 2.1. The policy names every selectable provider, Brave
Search (50-word/400-char cap, 90-day retention), the on-device-only Apple
Intelligence path, local storage/Keychain details, and deletion, per
Guideline 5.1.2(i).

### 3. Age gate (4.7.5) — DONE

First launch presents a non-dismissable birth-year gate
(`Views/AgeGateView.swift`, policy in `Settings/AgeGate.swift`). 17+ passes;
an under-age declaration persistently blocks the app. The declared year is
stored only in UserDefaults (`ageGate.declaredBirthYear`). Mention it in the
review notes.

## App Store Connect setup

### Listing copy — ready to paste

**Name:** `Parley: Private AI Chat` (23 chars — several unrelated "Parley"
and "Parley AI" apps already exist on the store, so the bare name is likely
unavailable and the qualifier disambiguates in search results anyway; the
home-screen display name stays just **Parley**).

**Subtitle (30 chars max):** `Your keys. Your conversations.` (30 chars —
don't repeat the name's "Private AI Chat" in the subtitle; Apple ignores
duplicated terms)

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
The build now has a **declared-age gate on first run** (17+, persistent
under-age block) — point reviewers at it in the review notes.

### Review notes — write these

Reviewers have no API keys, so say this explicitly:

> Parley defaults to Apple's on-device model (Apple Intelligence), which
> needs no API key or network access — please test on an Apple
> Intelligence–capable device running iOS 26.5+ with Apple Intelligence
> enabled in Settings. To test a cloud provider instead, open Settings →
> Provider, choose one, and paste an API key.
>
> Per Guideline 4.7.5, first launch presents a declared-age gate: users
> must enter a birth year, and anyone under 17 is persistently blocked
> from the app.
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

- [ ] `https://dict.ai-dictionary.org/privacy` and `/support` are **live**
      and match `website/privacy.html` / `website/support.html`.
- [ ] `SupportInfo.isConfigured` returns true — check Settings shows the
      Support section and a reply's context menu shows "Report response".
- [ ] Clean install shows the age gate; a passing year proceeds, an
      under-17 year blocks and stays blocked after relaunch.
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

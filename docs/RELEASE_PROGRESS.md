# Release progress — Parley

Working log for the App Store push. Read this first when resuming.
Companion doc: `APP_STORE_RELEASE.md` (the submission checklist and
listing copy).

## Where things stand

The app has been rebranded **Parley** (display name only — bundle ID
stays `com.robert.demo-app` deliberately, see below), given a new icon,
and **all code-side compliance work is done**: support info filled, age
gate built, known bugs fixed, privacy/support pages written. What
remains is hosting the two web pages and the App Store Connect work,
both of which only the account owner can do. See "Next steps".

## Done — committed and pushed (`origin main`)

| Commit | What |
| --- | --- |
| `ac7092c` | Apple Intelligence on-device model as a chat provider |
| `b6cacb0` | Web search (Brave) and voice input |
| `9b62958` | Handle Apple guardrail errors instead of leaking Apple's text |
| `ced8f34` | Markdown rendering for assistant replies |
| `2107685` | Source folder reorg (App/Models/Services/Settings/Views) |
| `a64ad1e` | Mic and web-search buttons no longer disable each other |
| `4146d0f` | Rename project demo-app → ai-chat |
| `bd8f724` | App Store prep: removed unused `remote-notification` background mode; `PrivacyInfo.xcprivacy` (no tracking, no collection, UserDefaults CA92.1); `ITSAppUsesNonExemptEncryption=false`; launch `fatalError` → in-memory fallback + alert; Report-response context action; gated Support section in Settings; keyless on-device default on first run; VoiceOver labels; `APP_STORE_RELEASE.md` |

## Done — this session (about to be committed)

- **Rebrand to Parley**: `INFOPLIST_KEY_CFBundleDisplayName = Parley`
  (both configs in `project.pbxproj`), mic usage string, store-failure
  alert (`App/AIChatApp.swift:59`), report-email subject
  (`Settings/SupportInfo.swift:58`).
- **New icon**, replacing the indigo/violet bubbles (deliberately not
  indigo — every AI app is indigo):
  - Concept: single speech bubble tilted 4°, three rising dots.
  - Light: coral→amber gradient, white bubble, coral dots.
    Dark: charcoal, gradient bubble. Tinted: grayscale on black.
  - Generated deterministically by `scripts/make-icon.swift`
    (CoreGraphics, no alpha). Regenerate with:
    `swift scripts/make-icon.swift ai-chat/Assets.xcassets/AppIcon.appiconset`
  - All three PNGs verified 1024×1024, `hasAlpha: no` via `sips`.
- **Listing copy** (name, subtitle, description, keywords, promo text)
  written into `APP_STORE_RELEASE.md` under "Listing copy".

## Deliberate decisions (do not "fix" these)

- **Bundle ID stays `com.robert.demo-app`** — changing it orphans
  existing installs and their data. Review notes pre-empt the 2.2
  "is this a demo?" question. Commented in `project.pbxproj`.
- **Keychain service stays `"com.demo-app.byok"`**
  (`Services/KeychainStore.swift:27`) — renaming orphans saved keys.
- **Zero SPM dependencies** — deliberate; keep it that way.
- **First-run default** (`Settings/ChatSettings.swift`, init
  ~:100-113): if no stored base URL and Apple Intelligence is
  available → on-device preset (keyless, reviewer-friendly);
  otherwise OpenAI `gpt-4o-mini`. A stored value always wins.

## Done — 2026-08-03 session

- **`Settings/SupportInfo.swift` filled**: `ruobin.wang.us@gmail.com`,
  `https://dict.ai-dictionary.org/privacy`, `.../support`. Support
  section and Report action now visible.
- **Age gate built** (Guideline 4.7.5): `Settings/AgeGate.swift`
  (policy, unit-tested in `ai-chatTests/AgeGateTests.swift`) +
  `Views/AgeGateView.swift` (non-dismissable full-screen cover,
  birth-year wheel, persistent under-17 block). Wired in
  `Views/ContentView.swift`; the first-run Settings sheet now waits
  for the gate to pass so the two never compete for presentation.
- **Bugs fixed**: Brave 429 now retries once (`WebResearchService`
  `where` clause applied to both patterns); `WebSourcesPayload` /
  `PersistedWebSource` marked `nonisolated` (Codable isolation
  warning gone).
- **Privacy policy + support page written**: `website/privacy.html`,
  `website/support.html` — self-contained, light/dark, ready to host.
- **Store name decided**: `Parley: Private AI Chat` (bare "Parley" is
  crowded/taken on the App Store); new 30-char subtitle. Listing copy
  updated in `APP_STORE_RELEASE.md`.

## Next steps, in order (account owner only)

1. **Host the two pages** at `https://dict.ai-dictionary.org/privacy`
   and `/support` (files in `website/`). Must be live before
   submission — App Review follows the in-app links.
2. **Verify on a device/simulator** — age gate flow, Markdown
   rendering, and the mic/web-search button fix have only been
   verified at build/logic level. Run the "Verify before every
   upload" checklist in `APP_STORE_RELEASE.md`.
3. **App Store Connect**: create the app record, paste the listing
   copy, screenshots, privacy questionnaire ("Data is not
   collected"), age rating, review notes (all drafted in
   `APP_STORE_RELEASE.md`), archive and submit.

## Build commands

```sh
# Device build (no signing)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ai-chat.xcodeproj -scheme ai-chat \
  -destination 'generic/platform=iOS' -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO

# Test build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ai-chat.xcodeproj -scheme ai-chat \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build-for-testing
```

Notes: `xcode-select` points at CommandLineTools, hence the
`DEVELOPER_DIR` prefix. Project/target/scheme are `ai-chat`, module is
`AIChat`. The target uses a file-system-synchronized group — new files
under `ai-chat/` are picked up with no pbxproj edits.

## File map (release-relevant)

| File | Role |
| --- | --- |
| `docs/APP_STORE_RELEASE.md` | Submission checklist, listing copy, review notes |
| `scripts/make-icon.swift` | Deterministic icon generator |
| `ai-chat/Settings/SupportInfo.swift` | Placeholder contact/policy values — fill before shipping |
| `ai-chat/Settings/ChatSettings.swift` | First-run defaults, provider presets |
| `ai-chat/Views/ContentView.swift` | First-run gate; where the age gate goes |
| `ai-chat/PrivacyInfo.xcprivacy` | Privacy manifest (verified present in built bundle) |
| `ai-chat/Info.plist` | Mic string, encryption exemption |
| `ai-chat/Services/WebResearchService.swift` | 429 retry bug to fix |
| `ai-chat/Models/Message.swift` | Codable isolation warnings to fix |

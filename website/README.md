# Parley web pages

Static pages required for App Store submission. They must be live at
**exactly** these URLs before submitting — App Review follows the links
inside the app (`Parley/Settings/SupportInfo.swift`), and a 404 is a
rejection risk under Guideline 2.1:

| File | Must be served at |
| --- | --- |
| `privacy.html` | `https://parley.ai-dictionary.org/privacy` |
| `support.html` | `https://parley.ai-dictionary.org/support` |

Notes:

- The URLs are extensionless (`/privacy`, not `/privacy.html`). Most
  static hosts (Cloudflare Pages, Netlify, GitHub Pages) serve
  `privacy.html` at `/privacy` automatically; otherwise rename each file
  to `privacy/index.html` / `support/index.html`.
- The privacy URL must also be entered as the privacy policy URL in App
  Store Connect, and the support URL as the App Store "Support URL". All
  three places (app, App Store Connect, hosting) must match.
- Both pages are fully self-contained (inline CSS, light/dark aware,
  no external assets). If the privacy policy changes, update the
  effective date at the top of `privacy.html`.
- If the domain ever changes, update `SupportInfo.swift`, App Store
  Connect, and these files' cross-links together.

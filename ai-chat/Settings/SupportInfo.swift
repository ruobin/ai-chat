//
//  SupportInfo.swift
//  ai-chat
//
//  Contact and policy details required for App Store distribution.
//
//  App Review Guideline 1.5 requires published contact information, and
//  4.7.1 (which explicitly covers chatbots) additionally requires a way to
//  report objectionable content. Guideline 5.1.1(i) requires a privacy
//  policy reachable *inside* the app, not just in App Store Connect.
//
//  ⚠️ These are the only submission values that cannot be derived from the
//  code — fill them in before archiving. `isConfigured` is false while any
//  placeholder remains, and the Settings UI hides the affected rows rather
//  than shipping a dead mailto: or a 404 link, either of which is itself a
//  rejection risk under Guideline 2.1.
//

import Foundation

enum SupportInfo {
    /// Address shown in Settings and used for content reports.
    static let contactEmail = "ruobin.wang.us@gmail.com"

    /// Must match the privacy policy URL entered in App Store Connect.
    static let privacyPolicyURL = URL(string: "https://parley.ai-dictionary.org/privacy")!

    /// Public support page, used as the App Store "Support URL".
    static let supportURL = URL(string: "https://parley.ai-dictionary.org/support")!

    /// False while any placeholder above is still in place.
    static var isConfigured: Bool {
        !contactEmail.contains("REPLACE_ME")
            && !privacyPolicyURL.absoluteString.contains("example.com")
            && !supportURL.absoluteString.contains("example.com")
    }

    /// Builds a prefilled report email for one assistant message. The body
    /// quotes the reported text so a report is actionable without asking the
    /// user to copy anything by hand. Conversation history is deliberately
    /// not included — only the single message being reported.
    static func reportURL(for content: String, provider: String) -> URL? {
        guard isConfigured else { return nil }
        let excerpt = String(content.prefix(1500))
        let body = """
            Describe the problem with this response:


            ---
            Provider: \(provider)
            Reported response:
            \(excerpt)
            """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = contactEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Parley — report a response"),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}

//
//  demo_appTests.swift
//  demo-appTests
//
//  Created by robert on 8/2/26.
//

import Testing
import Foundation
@testable import demo_app

struct demo_appTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

}

/// Covers the per-provider API key scoping in `ChatSettings`. Each test uses
/// its own `UserDefaults` suite and its own unique fake base URLs (rather
/// than the real provider URLs, which could collide with another test
/// running concurrently against the same global Keychain), and cleans up
/// any Keychain entries it creates.
struct ChatSettingsAPIKeyScopingTests {
    private func makeSettings(suiteName: String) -> ChatSettings {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ChatSettings(defaults: defaults)
    }

    private func cleanUp(_ urls: [String]) {
        for url in urls {
            var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
            while normalized.hasSuffix("/") { normalized.removeLast() }
            KeychainStore.delete(for: "api-key::\(normalized)")
        }
    }

    @Test func keysAreIsolatedPerProvider() throws {
        let suite = "ChatSettingsTests.keysAreIsolatedPerProvider"
        let urlA = "https://provider-a.test/v1"
        let urlB = "https://provider-b.test/v1"
        defer { cleanUp([urlA, urlB]) }
        let settings = makeSettings(suiteName: suite)

        settings.baseURLString = urlA
        try settings.setAPIKey("secret-a")

        settings.baseURLString = urlB
        #expect(settings.hasAPIKey == false, "switching providers must not leak the previous provider's key")
        try settings.setAPIKey("secret-b")

        settings.baseURLString = urlA
        #expect(settings.apiKey == "secret-a", "provider A's key must survive switching away and back")

        settings.baseURLString = urlB
        #expect(settings.apiKey == "secret-b", "provider B's key must be independent of provider A's")
    }

    @Test func applyPresetRestoresLastUsedModelPerProvider() throws {
        let suite = "ChatSettingsTests.applyPresetRestoresLastUsedModelPerProvider"
        let settings = makeSettings(suiteName: suite)
        defer { cleanUp([ProviderPreset.openAI.defaultBaseURL, ProviderPreset.anthropic.defaultBaseURL]) }

        settings.applyPreset(.openAI)
        settings.modelName = "gpt-4.1"

        settings.applyPreset(.anthropic)
        #expect(settings.modelName == ProviderPreset.anthropic.defaultModel)

        settings.applyPreset(.openAI)
        #expect(settings.modelName == "gpt-4.1", "the custom model chosen for OpenAI should be remembered, not reset to the preset default")
    }

    @Test func legacySharedKeyMigratesToActiveProviderOnFirstLaunch() throws {
        let suite = "ChatSettingsTests.legacySharedKeyMigratesToActiveProviderOnFirstLaunch"
        let url = "https://provider-legacy-migration.test/v1"
        defer {
            cleanUp([url])
            KeychainStore.delete(for: "api-key")
        }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(url, forKey: "settings.baseURL")
        try KeychainStore.save("legacy-secret", for: "api-key")

        let settings = ChatSettings(defaults: defaults)

        #expect(settings.apiKey == "legacy-secret")
        #expect(KeychainStore.read(for: "api-key") == nil, "legacy shared key should be deleted after migrating")
    }
}

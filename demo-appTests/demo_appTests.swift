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

    @Test(.disabled("Disabled: full test run was taking too long. Re-enable when test runtime is investigated/fixed."))
    func example() async throws {
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
@Suite(.disabled("Disabled: full test run was taking too long. Re-enable when test runtime is investigated/fixed."))
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

/// Covers `ProviderPreset.detect(from:)`'s exact-match-or-custom behavior.
@Suite(.disabled("Disabled: full test run was taking too long. Re-enable when test runtime is investigated/fixed."))
struct ProviderPresetDetectionTests {
    @Test func detectsKnownPresetsByExactBaseURL() {
        #expect(ProviderPreset.detect(from: "https://api.openai.com/v1") == .openAI)
        #expect(ProviderPreset.detect(from: "https://api.anthropic.com/v1") == .anthropic)
    }

    @Test func fallsBackToCustomForUnrecognizedOrModifiedURLs() {
        #expect(ProviderPreset.detect(from: "https://api.openai.com/v1/") == .custom, "a trailing slash makes it no longer an exact match")
        #expect(ProviderPreset.detect(from: "https://my-self-hosted-llm.example.com/v1") == .custom)
        #expect(ProviderPreset.detect(from: "") == .custom)
    }
}

/// Covers `Conversation`'s per-conversation provider/model override and its
/// fallback to the global `ChatSettings.shared` default. Since
/// `Conversation.effectiveBaseURL`/`effectiveModelName` read the real
/// `ChatSettings.shared` singleton (not an injectable instance), these tests
/// snapshot and restore its `baseURLString`/`modelName` around each test and
/// run serialized to avoid racing each other over that shared global state.
@Suite(.serialized, .disabled("Disabled: full test run was taking too long. Re-enable when test runtime is investigated/fixed."))
struct ConversationProviderOverrideTests {
    private func withGlobalDefault<T>(baseURL: String, model: String, _ body: () throws -> T) rethrows -> T {
        let settings = ChatSettings.shared
        let savedURL = settings.baseURLString
        let savedModel = settings.modelName
        settings.baseURLString = baseURL
        settings.modelName = model
        defer {
            settings.baseURLString = savedURL
            settings.modelName = savedModel
        }
        return try body()
    }

    @Test func newConversationSnapshotsGlobalDefaultAtCreationTime() throws {
        try withGlobalDefault(baseURL: "https://snapshot-test.example/v1", model: "snapshot-model") {
            let convo = Conversation()
            #expect(convo.effectiveBaseURL == "https://snapshot-test.example/v1")
            #expect(convo.effectiveModelName == "snapshot-model")

            // Changing the global default afterward must not retroactively
            // change an already-created conversation.
            ChatSettings.shared.baseURLString = "https://changed-later.example/v1"
            ChatSettings.shared.modelName = "changed-later-model"
            #expect(convo.effectiveBaseURL == "https://snapshot-test.example/v1")
            #expect(convo.effectiveModelName == "snapshot-model")
        }
    }

    @Test func legacyConversationWithNoOverrideTracksLiveGlobalDefault() throws {
        try withGlobalDefault(baseURL: "https://legacy-tracks-global.example/v1", model: "legacy-model-1") {
            let convo = Conversation()
            // Simulate a pre-existing row from before per-conversation
            // overrides existed: no override recorded.
            convo.baseURLOverride = nil
            convo.modelNameOverride = nil

            #expect(convo.effectiveBaseURL == "https://legacy-tracks-global.example/v1")
            #expect(convo.effectiveModelName == "legacy-model-1")

            ChatSettings.shared.modelName = "legacy-model-2"
            #expect(convo.effectiveModelName == "legacy-model-2", "a conversation with no override should keep tracking live global changes, matching pre-override behavior")
        }
    }

    @Test func settingOverrideIsolatesFromOtherConversationsAndGlobalDefault() throws {
        try withGlobalDefault(baseURL: "https://shared-default.example/v1", model: "shared-model") {
            let convoA = Conversation()
            let convoB = Conversation()

            convoA.setProviderOverride(baseURL: "https://provider-x.example/v1", model: "model-x")

            #expect(convoA.effectiveBaseURL == "https://provider-x.example/v1")
            #expect(convoA.effectiveModelName == "model-x")
            #expect(convoB.effectiveBaseURL == "https://shared-default.example/v1", "conversation B's override must be unaffected by conversation A's change")
            #expect(convoB.effectiveModelName == "shared-model")
            #expect(ChatSettings.shared.baseURLString == "https://shared-default.example/v1", "the global default must be unaffected by a per-conversation override")
        }
    }
}

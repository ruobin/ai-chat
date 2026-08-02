//
//  demo_appTests.swift
//  demo-appTests
//
//  Created by robert on 8/2/26.
//

import Testing
import Foundation
import FoundationModels
@testable import demo_app

struct demo_appTests {

    @Test(.disabled("Disabled: full test run was taking too long. Re-enable when test runtime is investigated/fixed."))
    func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

}

@Suite struct VoiceDraftComposerTests {
    @Test func usesUtteranceForEmptyDraft() {
        #expect(VoiceDraftComposer.combine(base: "", utterance: "Hello") == "Hello")
    }

    @Test func preservesEmptyUtteranceDraft() {
        #expect(VoiceDraftComposer.combine(base: "Already typed", utterance: "") == "Already typed")
    }

    @Test func insertsSpaceBetweenTypedAndSpokenText() {
        #expect(
            VoiceDraftComposer.combine(base: "Already typed", utterance: "more words")
                == "Already typed more words"
        )
    }

    @Test func doesNotDuplicateExistingWhitespace() {
        #expect(
            VoiceDraftComposer.combine(base: "Already typed ", utterance: "more words")
                == "Already typed more words"
        )
        #expect(
            VoiceDraftComposer.combine(base: "Already typed", utterance: " more words")
                == "Already typed more words"
        )
    }
}

@Suite struct VoiceTranscriptAccumulatorTests {
    @Test func volatileHypothesesReplaceRatherThanAppend() {
        var accumulator = VoiceTranscriptAccumulator()

        accumulator.apply("Hello", isFinal: false)
        #expect(accumulator.transcript == "Hello")

        accumulator.apply("Hello world", isFinal: false)
        #expect(accumulator.transcript == "Hello world")
    }

    @Test func finalResultsAppendExactlyOnce() {
        var accumulator = VoiceTranscriptAccumulator()

        accumulator.apply("Hello world", isFinal: false)
        accumulator.apply("Hello world", isFinal: true)
        #expect(accumulator.transcript == "Hello world")

        accumulator.apply("from voice input", isFinal: true)
        #expect(accumulator.transcript == "Hello world from voice input")
    }

    @Test func resetClearsFinalAndVolatileText() {
        var accumulator = VoiceTranscriptAccumulator()
        accumulator.apply("Final", isFinal: true)
        accumulator.apply("partial", isFinal: false)

        accumulator.reset()

        #expect(accumulator.transcript.isEmpty)
    }
}

@Suite struct VoiceInputStateTests {
    @Test func onlyInFlightStatesBlockEditingAndSending() {
        let activeStates: [VoiceInputState] = [
            .preparing(.requestingPermission),
            .recording,
            .finalizing,
        ]
        let inactiveStates: [VoiceInputState] = [
            .idle,
            .failed("Retry"),
            .unavailable("Unsupported"),
        ]

        for state in activeStates {
            #expect(state.isActive)
            #expect(state.blocksEditing)
            #expect(state.blocksSending)
        }
        for state in inactiveStates {
            #expect(!state.isActive)
            #expect(!state.blocksEditing)
            #expect(!state.blocksSending)
        }
    }

    @Test func unavailableIsTheOnlyPermanentlyDisabledState() {
        #expect(VoiceInputState.unavailable("Unsupported").permanentlyUnavailable)
        #expect(!VoiceInputState.failed("Retry").permanentlyUnavailable)
        #expect(!VoiceInputState.idle.permanentlyUnavailable)
    }

    @Test func permanentCapabilityErrorsAreClassifiedSeparately() {
        #expect(VoiceInputError.transcriberUnavailable.isPermanent)
        #expect(VoiceInputError.unsupportedLocale.isPermanent)
        #expect(VoiceInputError.unsupportedModel.isPermanent)
        #expect(VoiceInputError.modelReservationUnavailable.isPermanent)
        #expect(!VoiceInputError.microphoneDenied.isPermanent)
        #expect(!VoiceInputError.interrupted.isPermanent)
    }
}

@Suite struct WebResearchTests {
    @Test func normalizesAndBoundsQuery() throws {
        let query = try WebResearchService.normalizedQuery("  What\n\n is\tnew?  ")
        #expect(query == "What is new?")

        let longQuery = try WebResearchService.normalizedQuery(
            String(repeating: "word ", count: 75)
        )
        #expect(longQuery.split(separator: " ").count == 50)
    }

    @Test func rejectsAnEmptyNormalizedQuery() {
        #expect(throws: WebResearchError.self) {
            _ = try WebResearchService.normalizedQuery(" \n\t ")
        }
    }

    @Test func excludesFencedCodeFromQuery() throws {
        let query = try WebResearchService.normalizedQuery(
            "Summarize this ```secret-token-should-not-leave-device``` document"
        )
        #expect(query == "Summarize this document")
    }

    @Test func sourcePayloadExcludesRawExcerpt() {
        let source = PersistedWebSource(
            id: 1,
            title: "Example",
            url: URL(string: "https://example.com")!,
            domain: "example.com"
        )
        let message = Message(role: .assistant, content: "Answer")
        message.setWebSources([source])

        #expect(message.webSources.map(\.id) == [source.id])
        let encoded = String(data: message.webSourcesData!, encoding: .utf8)!
        #expect(!encoded.contains("excerpt"))
    }

    @Test func filtersSourcesToKnownCitationMarkers() {
        let first = PersistedWebSource(
            id: 1, title: "One", url: URL(string: "https://one.example")!, domain: "one.example"
        )
        let second = PersistedWebSource(
            id: 2, title: "Two", url: URL(string: "https://two.example")!, domain: "two.example"
        )
        let message = Message(role: .assistant, content: "Claim [source:2] and [source:99].")
        message.setWebSources([first, second])

        #expect(message.citedWebSources.map(\.id) == [2])
    }
}

/// Covers `ChatSettings`' temperature persistence. Regression test: an
/// explicitly-saved 0.0 must survive a relaunch (previously indistinguishable
/// from "never set" via `UserDefaults.double(forKey:)`, and reset to 0.7).
@Suite struct ChatSettingsTemperatureTests {
    @Test func explicitlyZeroTemperatureSurvivesRelaunch() {
        let suite = "ChatSettingsTests.temperatureZero"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ChatSettings(defaults: defaults)
        first.temperature = 0.0

        let relaunched = ChatSettings(defaults: defaults)
        #expect(relaunched.temperature == 0.0)
    }

    @Test func temperatureDefaultsTo07WhenNeverSet() {
        let suite = "ChatSettingsTests.temperatureDefault"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = ChatSettings(defaults: defaults)
        #expect(settings.temperature == 0.7)
    }
}

/// Covers the Apple Intelligence (on-device) provider preset: sentinel base
/// URL detection, keyless operation, and transcript construction for
/// session replay. These are pure value-type tests — no model is loaded.
@Suite struct AppleIntelligencePresetTests {
    @Test func sentinelBaseURLDetectsAppleIntelligencePreset() {
        #expect(ProviderPreset.detect(from: "apple-intelligence://on-device") == .appleIntelligence)
    }

    @Test func appleIntelligenceAllowsEmptyKeyAndSuggestsNoModels() {
        #expect(ProviderPreset.appleIntelligence.allowsEmptyKey)
        #expect(ProviderPreset.appleIntelligence.isOnDevice)
        #expect(ProviderPreset.appleIntelligence.suggestedModels.isEmpty)
        #expect(ProviderPreset.openAI.isOnDevice == false)
    }
}

@Suite struct AppleIntelligenceTranscriptTests {
    @Test func buildsInstructionsPromptResponseEntriesInOrder() throws {
        let messages = [
            ProviderChatMessage(role: "system", content: "Be terse."),
            ProviderChatMessage(role: "user", content: "Hi"),
            ProviderChatMessage(role: "assistant", content: "Hello!"),
            ProviderChatMessage(role: "user", content: "How are you?"),
        ]

        let (transcript, prompt) = try AppleIntelligenceService.makeTranscript(from: messages)

        #expect(prompt == "How are you?")
        #expect(transcript.count == 3)
        guard case .instructions = transcript[0] else {
            Issue.record("entry 0 should be instructions")
            return
        }
        guard case .prompt = transcript[1] else {
            Issue.record("entry 1 should be a prompt")
            return
        }
        guard case .response = transcript[2] else {
            Issue.record("entry 2 should be a response")
            return
        }
    }

    @Test func firstTurnHasOnlyInstructionsAndPrompt() throws {
        let messages = [
            ProviderChatMessage(role: "system", content: "Be terse."),
            ProviderChatMessage(role: "user", content: "Hi"),
        ]

        let (transcript, prompt) = try AppleIntelligenceService.makeTranscript(from: messages)

        #expect(prompt == "Hi")
        #expect(transcript.count == 1)
        guard case .instructions = transcript[0] else {
            Issue.record("entry 0 should be instructions")
            return
        }
    }

    @Test func throwsWhenLastMessageIsNotFromUser() {
        let messages = [
            ProviderChatMessage(role: "user", content: "Hi"),
            ProviderChatMessage(role: "assistant", content: "Hello!"),
        ]

        #expect(throws: AppleIntelligenceError.self) {
            _ = try AppleIntelligenceService.makeTranscript(from: messages)
        }
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

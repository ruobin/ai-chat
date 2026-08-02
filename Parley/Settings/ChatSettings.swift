//
//  ChatSettings.swift
//  Parley
//
//  User-configurable settings for the chat provider. API key lives in Keychain;
//  everything else is mirrored to UserDefaults so it survives launches.
//

import Foundation
import Observation
import SwiftUI

@Observable
final class ChatSettings {
    static let shared = ChatSettings()

    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: Keys.baseURL) }
    }
    var modelName: String {
        didSet {
            defaults.set(modelName, forKey: Keys.model)
            modelsByProvider[normalizedBaseURL(baseURLString)] = modelName
        }
    }
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }
    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    /// Remembers the last model used with each base URL, so switching
    /// providers and back doesn't lose a custom model choice. Keyed by the
    /// normalized base URL (see `keychainAccount(for:)`), same scoping as
    /// API keys.
    private var modelsByProvider: [String: String] {
        didSet { defaults.set(modelsByProvider, forKey: Keys.modelsByProvider) }
    }

    /// API key for the *currently active* provider (`baseURLString`).
    /// Each provider's key is stored under its own Keychain account, so
    /// setting a key for Anthropic does not overwrite or get overwritten by
    /// OpenAI's key — see `keychainAccount(for:)`.
    var hasAPIKey: Bool {
        !(apiKey ?? "").isEmpty
    }

    var apiKey: String? {
        apiKey(forBaseURL: baseURLString)
    }

    /// Reads the stored key for an arbitrary base URL, independent of which
    /// provider is currently active.
    func apiKey(forBaseURL baseURL: String) -> String? {
        KeychainStore.read(for: keychainAccount(for: baseURL))
    }

    func hasAPIKey(forBaseURL baseURL: String) -> Bool {
        !(apiKey(forBaseURL: baseURL) ?? "").isEmpty
    }

    /// Best-effort detection of which preset the current base URL matches.
    /// Falls back to `.custom` so the UI shows "Custom" for unknown endpoints.
    var detectedPreset: ProviderPreset {
        ProviderPreset.detect(from: baseURLString)
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let baseURL = "settings.baseURL"
        static let model = "settings.model"
        static let systemPrompt = "settings.systemPrompt"
        static let temperature = "settings.temperature"
        static let theme = "settings.theme"
        static let modelsByProvider = "settings.modelsByProvider"
        /// Pre-multi-provider single shared API key account. Migrated away
        /// from on first launch after the per-provider key change; see
        /// `migrateLegacyAPIKeyIfNeeded()`.
        static let legacyAPIKey = "api-key"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Initialize modelsByProvider before any property whose didSet
        // touches it (modelName), so that observer is never operating on an
        // uninitialized dictionary regardless of Swift's exact didSet-during-
        // init timing.
        self.modelsByProvider = defaults.dictionary(forKey: Keys.modelsByProvider) as? [String: String]
            ?? [:]
        // On a fresh install, prefer the on-device model when the device
        // supports it: it needs no API key, so the app is usable immediately
        // rather than dead-ending on "No API key set". That matters for App
        // Review, whose testers have no keys, and it's the better default for
        // any new user too. A stored value always wins, so this never
        // overrides a choice someone has already made.
        let storedBaseURL = defaults.string(forKey: Keys.baseURL)
        let preferOnDevice = storedBaseURL == nil && AppleIntelligenceService.isAvailable
        self.baseURLString = storedBaseURL
            ?? (preferOnDevice
                ? ProviderPreset.appleIntelligence.defaultBaseURL
                : "https://api.openai.com/v1")
        self.modelName = defaults.string(forKey: Keys.model)
            ?? (preferOnDevice
                ? ProviderPreset.appleIntelligence.defaultModel
                : "gpt-4o-mini")
        self.systemPrompt = defaults.string(forKey: Keys.systemPrompt)
            ?? "You are a helpful assistant."
        // Use object(forKey:) rather than double(forKey:) so an explicitly
        // saved 0.0 isn't mistaken for "never set" and replaced with the
        // default on the next launch.
        if let storedTemp = defaults.object(forKey: Keys.temperature) as? Double {
            self.temperature = storedTemp
        } else {
            self.temperature = 0.7
        }
        self.theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:))
            ?? .system
        migrateLegacyAPIKeyIfNeeded()
    }

    /// One-time migration from the single shared API key (used before
    /// providers had independently-scoped keys) to the currently active
    /// provider's scoped account, so upgrading users don't lose their key.
    /// A no-op on every launch after the first, since the legacy entry is
    /// deleted once migrated.
    private func migrateLegacyAPIKeyIfNeeded() {
        guard let legacyKey = KeychainStore.read(for: Keys.legacyAPIKey) else { return }
        let targetAccount = keychainAccount(for: baseURLString)
        if KeychainStore.read(for: targetAccount) == nil {
            try? KeychainStore.save(legacyKey, for: targetAccount)
        }
        KeychainStore.delete(for: Keys.legacyAPIKey)
    }

    /// Keychain account name for a given base URL. Trailing slashes and
    /// surrounding whitespace are trimmed so e.g. "https://api.x.com/v1" and
    /// "https://api.x.com/v1/" map to the same stored key.
    private func keychainAccount(for baseURL: String) -> String {
        "api-key::\(normalizedBaseURL(baseURL))"
    }

    /// Saves (or deletes, if `key` is nil/blank) the API key for the
    /// currently active provider (`baseURLString`). Other providers' keys
    /// are unaffected.
    func setAPIKey(_ key: String?) throws {
        let account = keychainAccount(for: baseURLString)
        if let key, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            try KeychainStore.save(key.trimmingCharacters(in: .whitespaces), for: account)
        } else {
            KeychainStore.delete(for: account)
        }
    }

    /// Switches to `preset`: updates the base URL (unless it's `.custom`,
    /// which keeps whatever URL is currently set), then restores whichever
    /// model was last used with that base URL, falling back to the preset's
    /// default model.
    func applyPreset(_ preset: ProviderPreset) {
        if !preset.defaultBaseURL.isEmpty {
            baseURLString = preset.defaultBaseURL
        }
        if let remembered = modelsByProvider[normalizedBaseURL(baseURLString)] {
            modelName = remembered
        } else if !preset.defaultModel.isEmpty {
            modelName = preset.defaultModel
        }
    }

    /// The model last used with `baseURL`, if any, independent of which
    /// provider/conversation is currently active. Used when building a
    /// picker for a specific conversation's override, so it can default to
    /// the same "last used with this provider" model that `applyPreset`
    /// would pick for the global settings.
    func rememberedModel(forBaseURL baseURL: String) -> String? {
        modelsByProvider[normalizedBaseURL(baseURL)]
    }

    /// Records `model` as the last-used model for `baseURL`, without
    /// affecting the current global `baseURLString`/`modelName`. Used when a
    /// conversation-scoped picker changes a conversation's model, so that
    /// choice is also remembered as the provider-level default for next
    /// time (e.g. a brand-new conversation, or the global Settings screen).
    func rememberModel(_ model: String, forBaseURL baseURL: String) {
        modelsByProvider[normalizedBaseURL(baseURL)] = model
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}

enum ProviderPreset: String, CaseIterable, Identifiable {
    case appleIntelligence
    case openAI
    case anthropic
    case google
    case deepSeek
    case xAI
    case openRouter
    case ollama
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .google: return "Google (Gemini)"
        case .deepSeek: return "DeepSeek"
        case .xAI: return "xAI (Grok)"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    /// Whether this provider is the on-device Apple Intelligence model
    /// rather than an HTTP endpoint. Its `defaultBaseURL` is a sentinel
    /// (`apple-intelligence://on-device`) that never collides with a real
    /// URL, so per-conversation overrides, per-provider model memory, and
    /// `detect(from:)` all keep working unchanged; `ChatDetailView`
    /// branches on this to route generation to `AppleIntelligenceService`
    /// instead of `ChatService`.
    var isOnDevice: Bool {
        self == .appleIntelligence
    }

    var defaultBaseURL: String {
        switch self {
        case .appleIntelligence: return "apple-intelligence://on-device"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .google: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .appleIntelligence: return "On-device"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-6"
        case .google: return "gemini-2.5-flash"
        case .deepSeek: return "deepseek-chat"
        case .xAI: return "grok-2-latest"
        case .openRouter: return "openai/gpt-4o-mini"
        case .ollama: return "llama3.1"
        case .custom: return ""
        }
    }

    /// Free-form suggestions shown beneath the model field to make BYOK setup faster.
    var suggestedModels: [String] {
        switch self {
        case .appleIntelligence: return []
        case .openAI: return ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini"]
        case .anthropic: return ["claude-sonnet-4-6", "claude-opus-5", "claude-haiku-4-5"]
        case .google: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"]
        case .deepSeek: return ["deepseek-chat", "deepseek-reasoner"]
        case .xAI: return ["grok-2-latest", "grok-2", "grok-beta", "grok-vision-beta"]
        case .openRouter: return ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "meta-llama/llama-3.1-70b-instruct"]
        case .ollama: return ["llama3.1", "llama3.2", "mistral", "qwen2.5", "phi3"]
        case .custom: return []
        }
    }

    var infoNote: String? {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence's on-device model (iOS 26+). No API key, no network — generation runs entirely on this device. Requires an Apple Intelligence–capable device with Apple Intelligence enabled."
        case .openAI:
            return "OpenAI's API. Get a key at platform.openai.com."
        case .anthropic:
            return "Anthropic's OpenAI-compatible endpoint for Claude models. Get a key at console.anthropic.com. Note: this compatibility layer doesn't support every OpenAI feature (see Anthropic's docs)."
        case .google:
            return "Google's OpenAI-compatible endpoint for Gemini models. Get a key at aistudio.google.com."
        case .deepSeek:
            return "DeepSeek's OpenAI-compatible endpoint. Get a key at platform.deepseek.com."
        case .xAI:
            return "xAI's Grok models. Get a key at console.x.ai."
        case .openRouter:
            return "OpenRouter routes to many providers. Get a key at openrouter.ai."
        case .ollama:
            return "Local Ollama server with the OpenAI-compatible shim. No API key required, but you can save one if your setup needs it."
        case .custom:
            return "Any endpoint that implements /v1/chat/completions (vLLM, LM Studio, Together, etc.)."
        }
    }

    /// Providers that don't require an API key.
    var allowsEmptyKey: Bool {
        self == .appleIntelligence || self == .ollama || self == .custom
    }

    /// Best-effort detection of which preset a base URL matches by exact
    /// string equality with `defaultBaseURL`, falling back to `.custom` for
    /// unrecognized endpoints (including edited variants of a known
    /// endpoint, e.g. with a trailing slash added).
    static func detect(from baseURL: String) -> ProviderPreset {
        allCases.first { preset in
            !preset.defaultBaseURL.isEmpty && preset.defaultBaseURL == baseURL
        } ?? .custom
    }
}

/// User-selectable appearance for the app, independent of the system-wide
/// setting.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.righthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// Maps to the `preferredColorScheme` value; `nil` follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

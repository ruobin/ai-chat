//
//  ChatSettings.swift
//  demo-app
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
        ProviderPreset.allCases.first { preset in
            !preset.defaultBaseURL.isEmpty && preset.defaultBaseURL == baseURLString
        } ?? .custom
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
        self.baseURLString = defaults.string(forKey: Keys.baseURL)
            ?? "https://api.openai.com/v1"
        self.modelName = defaults.string(forKey: Keys.model)
            ?? "gpt-4o-mini"
        self.systemPrompt = defaults.string(forKey: Keys.systemPrompt)
            ?? "You are a helpful assistant."
        let storedTemp = defaults.double(forKey: Keys.temperature)
        self.temperature = storedTemp == 0 ? 0.7 : storedTemp
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

    private func normalizedBaseURL(_ baseURL: String) -> String {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }
}

enum ProviderPreset: String, CaseIterable, Identifiable {
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

    var defaultBaseURL: String {
        switch self {
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
        self == .ollama || self == .custom
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

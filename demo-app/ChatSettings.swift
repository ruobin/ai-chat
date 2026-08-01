//
//  ChatSettings.swift
//  demo-app
//
//  User-configurable settings for the chat provider. API key lives in Keychain;
//  everything else is mirrored to UserDefaults so it survives launches.
//

import Foundation
import Observation

@Observable
final class ChatSettings {
    static let shared = ChatSettings()

    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: Keys.baseURL) }
    }
    var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.model) }
    }
    var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: Keys.systemPrompt) }
    }
    var temperature: Double {
        didSet { defaults.set(temperature, forKey: Keys.temperature) }
    }

    var hasAPIKey: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    var apiKey: String? {
        KeychainStore.read(for: Keys.apiKey)
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
        static let apiKey = "api-key"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURLString = defaults.string(forKey: Keys.baseURL)
            ?? "https://api.openai.com/v1"
        self.modelName = defaults.string(forKey: Keys.model)
            ?? "gpt-4o-mini"
        self.systemPrompt = defaults.string(forKey: Keys.systemPrompt)
            ?? "You are a helpful assistant."
        let storedTemp = defaults.double(forKey: Keys.temperature)
        self.temperature = storedTemp == 0 ? 0.7 : storedTemp
    }

    func setAPIKey(_ key: String?) throws {
        if let key, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            try KeychainStore.save(key.trimmingCharacters(in: .whitespaces), for: Keys.apiKey)
        } else {
            KeychainStore.delete(for: Keys.apiKey)
        }
    }
}

enum ProviderPreset: String, CaseIterable, Identifiable {
    case openAI
    case deepSeek
    case xAI
    case groq
    case openRouter
    case ollama
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .xAI: return "xAI (Grok)"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .deepSeek: return "deepseek-chat"
        case .xAI: return "grok-2-latest"
        case .groq: return "llama-3.1-70b-versatile"
        case .openRouter: return "openai/gpt-4o-mini"
        case .ollama: return "llama3.1"
        case .custom: return ""
        }
    }

    /// Free-form suggestions shown beneath the model field to make BYOK setup faster.
    var suggestedModels: [String] {
        switch self {
        case .openAI: return ["gpt-4o-mini", "gpt-4o", "gpt-4.1", "gpt-4.1-mini", "o4-mini"]
        case .deepSeek: return ["deepseek-chat", "deepseek-reasoner"]
        case .xAI: return ["grok-2-latest", "grok-2", "grok-beta", "grok-vision-beta"]
        case .groq: return ["llama-3.1-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"]
        case .openRouter: return ["openai/gpt-4o-mini", "anthropic/claude-3.5-sonnet", "meta-llama/llama-3.1-70b-instruct"]
        case .ollama: return ["llama3.1", "llama3.2", "mistral", "qwen2.5", "phi3"]
        case .custom: return []
        }
    }

    var infoNote: String? {
        switch self {
        case .openAI:
            return "OpenAI's API. Get a key at platform.openai.com."
        case .deepSeek:
            return "DeepSeek's OpenAI-compatible endpoint. Get a key at platform.deepseek.com."
        case .xAI:
            return "xAI's Grok models. Get a key at console.x.ai."
        case .groq:
            return "Groq's fast inference for open models. Get a key at console.groq.com."
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
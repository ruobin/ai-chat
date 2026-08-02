//
//  ChatService.swift
//  demo-app
//
//  OpenAI-compatible streaming chat completions client.
//  Works with OpenAI, Anthropic, Google, DeepSeek, xAI, OpenRouter, Ollama,
//  LM Studio, vLLM, etc.
//

import Foundation

enum ChatProviderError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case http(Int, String?)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key set. Open Settings to add your key."
        case .invalidURL:
            return "Invalid API base URL."
        case .http(let code, let body):
            if let body, !body.isEmpty {
                return "API error \(code): \(body)"
            }
            return "API error \(code)"
        case .stream(let msg):
            return "Stream error: \(msg)"
        }
    }
}

struct ProviderChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct ProviderRequest: Encodable {
    let model: String
    let messages: [ProviderChatMessage]
    /// Omitted from the request body entirely when `nil`. Some models
    /// (OpenAI's reasoning family: o1/o3/o4-mini, gpt-5.x, etc.) reject any
    /// value other than the default and 400 if `temperature` is present at
    /// all with a non-default value, so we only send it when supported.
    let temperature: Double?
    let stream: Bool
}

private struct ProviderStreamChoice: Decodable {
    struct Delta: Decodable {
        let content: String?
        let role: String?
    }
    let delta: Delta?
    let finish_reason: String?
}

private struct ProviderStreamResponse: Decodable {
    let choices: [ProviderStreamChoice]
}

struct ProviderModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
}

private struct ProviderModelsResponse: Decodable {
    let data: [ProviderModel]
}

struct ChatService {
    let settings: ChatSettings

    init(settings: ChatSettings = .shared) {
        self.settings = settings
    }

    /// Best-effort detection of models that reject a non-default
    /// `temperature`. Covers OpenAI's reasoning family (o1, o3, o4-mini,
    /// gpt-5 and later) by name pattern, since new models in this family
    /// are released faster than this list can be kept exhaustive — the
    /// runtime retry in `streamCompletion` is the real safety net.
    static func modelSupportsCustomTemperature(_ model: String) -> Bool {
        let name = model.lowercased()
        if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") {
            return false
        }
        if name.hasPrefix("gpt-5") {
            return false
        }
        return true
    }

    private func makeRequestBody(
        model: String,
        messages: [ProviderChatMessage],
        includeTemperature: Bool
    ) throws -> Data {
        let body = ProviderRequest(
            model: model,
            messages: messages,
            temperature: includeTemperature ? settings.temperature : nil,
            stream: true
        )
        return try JSONEncoder().encode(body)
    }

    /// Streams a chat completion against `baseURL` using `model` and that
    /// provider's own stored API key, independent of whatever
    /// `settings.baseURLString`/`modelName` are currently set to. This lets
    /// each `Conversation` stream against its own remembered provider/model
    /// (see `Conversation.effectiveBaseURL`/`effectiveModelName`) without
    /// mutating (or being affected by concurrent mutation of) the global
    /// settings singleton. `onToken` is invoked on the main actor for each
    /// incremental content chunk as it arrives from the provider, so callers
    /// can safely update UI state from it.
    func streamCompletion(
        baseURL: String,
        model: String,
        messages: [ProviderChatMessage],
        onToken: @MainActor (String) -> Void
    ) async throws {
        let apiKey = settings.apiKey(forBaseURL: baseURL) ?? ""
        let preset = ProviderPreset.detect(from: baseURL)
        let requiresKey = !preset.allowsEmptyKey
        if requiresKey && apiKey.isEmpty {
            throw ChatProviderError.missingAPIKey
        }
        guard let base = URL(string: baseURL) else {
            throw ChatProviderError.invalidURL
        }
        let url = base.appendingPathComponent("chat/completions")

        func makeRequest(includeTemperature: Bool) throws -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            req.timeoutInterval = 120
            req.httpBody = try makeRequestBody(model: model, messages: messages, includeTemperature: includeTemperature)
            return req
        }

        var includeTemperature = Self.modelSupportsCustomTemperature(model)
        var req = try makeRequest(includeTemperature: includeTemperature)

        var (bytes, response) = try await URLSession.shared.bytes(for: req)
        var http = response as? HTTPURLResponse
        guard http != nil else {
            throw ChatProviderError.stream("Non-HTTP response")
        }

        if includeTemperature, let status = http?.statusCode, status == 400 {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 4000 { break }
            }
            if bodyText.localizedCaseInsensitiveContains("temperature") {
                // Provider rejected our temperature value even though we
                // didn't recognize this model as reasoning-only. Retry once
                // without it before giving up.
                includeTemperature = false
                req = try makeRequest(includeTemperature: includeTemperature)
                (bytes, response) = try await URLSession.shared.bytes(for: req)
                http = response as? HTTPURLResponse
                guard http != nil else {
                    throw ChatProviderError.stream("Non-HTTP response")
                }
            } else {
                throw ChatProviderError.http(400, bodyText.isEmpty ? nil : bodyText)
            }
        }

        guard let http, (200..<300).contains(http.statusCode) else {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 4000 { break }
            }
            throw ChatProviderError.http(http?.statusCode ?? -1, bodyText.isEmpty ? nil : bodyText)
        }

        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let parsed = try? decoder.decode(ProviderStreamResponse.self, from: data),
                  let token = parsed.choices.first?.delta?.content,
                  !token.isEmpty
            else { continue }
            onToken(token)
        }
    }

    /// Fetches the list of models available from `baseURL` (defaulting to
    /// the global `settings.baseURLString` if not specified) via the
    /// standard `GET /models` endpoint, sorted alphabetically by id. Uses
    /// that base URL's own stored API key, independent of which provider
    /// the global settings currently point at.
    func fetchModels(baseURL: String? = nil) async throws -> [ProviderModel] {
        let baseURL = baseURL ?? settings.baseURLString
        let apiKey = settings.apiKey(forBaseURL: baseURL) ?? ""
        let preset = ProviderPreset.detect(from: baseURL)
        let requiresKey = !preset.allowsEmptyKey
        if requiresKey && apiKey.isEmpty {
            throw ChatProviderError.missingAPIKey
        }
        guard let base = URL(string: baseURL) else {
            throw ChatProviderError.invalidURL
        }
        let url = base.appendingPathComponent("models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ChatProviderError.stream("Non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data.prefix(4000), encoding: .utf8)
            throw ChatProviderError.http(http.statusCode, bodyText)
        }
        do {
            let parsed = try JSONDecoder().decode(ProviderModelsResponse.self, from: data)
            return parsed.data.sorted { $0.id < $1.id }
        } catch {
            throw ChatProviderError.stream("Could not parse model list: \(error.localizedDescription)")
        }
    }
}

//
//  ChatService.swift
//  demo-app
//
//  OpenAI-compatible streaming chat completions client.
//  Works with OpenAI, Groq, OpenRouter, Ollama, LM Studio, vLLM, etc.
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
    let temperature: Double
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

struct ChatService {
    let settings: ChatSettings

    init(settings: ChatSettings = .shared) {
        self.settings = settings
    }

    /// Streams a chat completion. `onToken` is invoked for each incremental
    /// content chunk as it arrives from the provider.
    func streamCompletion(
        messages: [ProviderChatMessage],
        onToken: @escaping @Sendable (String) async -> Void
    ) async throws {
        let apiKey = settings.apiKey ?? ""
        let preset = settings.detectedPreset
        let requiresKey = !preset.allowsEmptyKey
        if requiresKey && apiKey.isEmpty {
            throw ChatProviderError.missingAPIKey
        }
        guard let base = URL(string: settings.baseURLString) else {
            throw ChatProviderError.invalidURL
        }
        let url = base.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 120

        let body = ProviderRequest(
            model: settings.modelName,
            messages: messages,
            temperature: settings.temperature,
            stream: true
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ChatProviderError.stream("Non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            var bodyText = ""
            for try await line in bytes.lines {
                bodyText += line
                if bodyText.count > 4000 { break }
            }
            throw ChatProviderError.http(http.statusCode, bodyText.isEmpty ? nil : bodyText)
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let parsed = try? JSONDecoder().decode(ProviderStreamResponse.self, from: data),
                  let token = parsed.choices.first?.delta?.content,
                  !token.isEmpty
            else { continue }
            await onToken(token)
        }
    }
}
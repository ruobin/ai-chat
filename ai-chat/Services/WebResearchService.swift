//
//  WebResearchService.swift
//  ai-chat
//
//  Bounded, citation-ready web evidence for every chat provider.
//

import Foundation

enum WebResearchError: LocalizedError {
    case missingKey
    case invalidKey
    case rateLimited
    case unavailable
    case noUsableResults
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add a Brave Search API key in Settings to search the web."
        case .invalidKey:
            return "Your Brave Search API key was rejected. Update it in Settings."
        case .rateLimited:
            return "Brave Search is rate-limited or your quota is exhausted. Try again shortly."
        case .unavailable:
            return "Web search is unavailable. Check your connection and try again."
        case .noUsableResults:
            return "Web search did not return usable sources for this message."
        case .invalidResponse:
            return "Web search returned an unexpected response. Please try again."
        }
    }
}

struct WebResearchBudget: Sendable {
    let maximumURLs: Int
    let maximumTokens: Int
    let maximumSnippets: Int
    let maximumTokensPerURL: Int
    let maximumSnippetsPerURL: Int
    let maximumPromptCharacters: Int
    let maximumExcerptCharacters: Int

    static let appleIntelligence = WebResearchBudget(
        maximumURLs: 3,
        maximumTokens: 1024,
        maximumSnippets: 6,
        maximumTokensPerURL: 512,
        maximumSnippetsPerURL: 2,
        maximumPromptCharacters: 2_500,
        maximumExcerptCharacters: 700
    )

    static let httpProvider = WebResearchBudget(
        maximumURLs: 5,
        maximumTokens: 2048,
        maximumSnippets: 12,
        maximumTokensPerURL: 512,
        maximumSnippetsPerURL: 3,
        maximumPromptCharacters: 8_000,
        maximumExcerptCharacters: 1_400
    )
}

struct WebSource: Hashable, Identifiable, Sendable {
    let id: Int
    let title: String
    let url: URL
    let domain: String
    let excerpt: String
}

struct PersistedWebSource: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let title: String
    let url: URL
    let domain: String
}

struct WebSourcesPayload: Codable, Sendable {
    let version: Int
    let sources: [PersistedWebSource]
}

struct WebResearch: Sendable {
    let query: String
    let promptContext: String
    let sources: [WebSource]

    var persistedSources: [PersistedWebSource] {
        sources.map {
            PersistedWebSource(id: $0.id, title: $0.title, url: $0.url, domain: $0.domain)
        }
    }
}

struct WebResearchService {
    private let settings: WebSearchSettings
    private let session: URLSession

    init(settings: WebSearchSettings = .shared, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    func research(query: String, budget: WebResearchBudget) async throws -> WebResearch {
        guard let key = settings.key(), !key.isEmpty else { throw WebResearchError.missingKey }
        let normalizedQuery = try Self.normalizedQuery(query)
        let request = try Self.makeRequest(query: normalizedQuery, key: key, budget: budget)

        let data = try await responseData(for: request)

        let decoded: BraveContextResponse
        do {
            decoded = try JSONDecoder().decode(BraveContextResponse.self, from: data)
        } catch {
            throw WebResearchError.invalidResponse
        }
        let sources = Self.makeSources(from: decoded, budget: budget)
        guard !sources.isEmpty else { throw WebResearchError.noUsableResults }
        return WebResearch(
            query: normalizedQuery,
            promptContext: Self.makePromptContext(sources: sources, budget: budget),
            sources: sources
        )
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        for attempt in 0..<2 {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebResearchError.unavailable }
            switch http.statusCode {
            case 200..<300:
                guard data.count <= 1_000_000 else { throw WebResearchError.invalidResponse }
                return data
            case 401, 403:
                throw WebResearchError.invalidKey
            case 429, 500..<600 where attempt == 0:
                try await Task.sleep(for: .milliseconds(500))
            case 429:
                throw WebResearchError.rateLimited
            case 500..<600:
                throw WebResearchError.unavailable
            default:
                throw WebResearchError.invalidResponse
            }
        }
        throw WebResearchError.unavailable
    }

    static func normalizedQuery(_ value: String) throws -> String {
        let withoutCode = removingFencedCodeBlocks(from: value)
        let filtered = withoutCode.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }
        let collapsed = String(String.UnicodeScalarView(filtered))
            .split(whereSeparator: \.isWhitespace)
            .prefix(50)
            .joined(separator: " ")
        let truncated = String(collapsed.prefix(400))
        guard !truncated.isEmpty else { throw WebResearchError.noUsableResults }
        return truncated
    }

    private static func removingFencedCodeBlocks(from value: String) -> String {
        var output = ""
        var remainder = value[...]
        while let opening = remainder.range(of: "```") {
            output += remainder[..<opening.lowerBound]
            let afterOpening = remainder[opening.upperBound...]
            guard let closing = afterOpening.range(of: "```") else { break }
            remainder = afterOpening[closing.upperBound...]
        }
        output += remainder
        return output
    }

    private static func makeRequest(
        query: String,
        key: String,
        budget: WebResearchBudget
    ) throws -> URLRequest {
        guard let url = URL(string: "https://api.search.brave.com/res/v1/llm/context") else {
            throw WebResearchError.invalidResponse
        }
        struct RequestBody: Encodable {
            let q: String
            let count: Int
            let maximum_number_of_urls: Int
            let maximum_number_of_tokens: Int
            let maximum_number_of_snippets: Int
            let maximum_number_of_tokens_per_url: Int
            let maximum_number_of_snippets_per_url: Int
            let context_threshold_mode: String
            let enable_local: Bool
        }
        let body = RequestBody(
            q: query,
            count: 10,
            maximum_number_of_urls: budget.maximumURLs,
            maximum_number_of_tokens: budget.maximumTokens,
            maximum_number_of_snippets: budget.maximumSnippets,
            maximum_number_of_tokens_per_url: budget.maximumTokensPerURL,
            maximum_number_of_snippets_per_url: budget.maximumSnippetsPerURL,
            context_threshold_mode: "balanced",
            enable_local: false
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func makeSources(
        from response: BraveContextResponse,
        budget: WebResearchBudget
    ) -> [WebSource] {
        var seenURLs = Set<URL>()
        var sources: [WebSource] = []
        for item in response.grounding.generic {
            guard sources.count < budget.maximumURLs,
                  let url = safeSourceURL(item.url),
                  seenURLs.insert(url).inserted,
                  let excerpt = sanitizedExcerpt(item.snippets.joined(separator: "\n"), limit: budget.maximumExcerptCharacters)
            else { continue }
            let metadata = response.sources[item.url]
            let domain = metadata?.hostname ?? url.host ?? "Source"
            let title = sanitizedTitle(metadata?.title ?? item.title ?? domain)
            sources.append(WebSource(
                id: sources.count + 1,
                title: title,
                url: url,
                domain: domain,
                excerpt: excerpt
            ))
        }
        return sources
    }

    private static func makePromptContext(sources: [WebSource], budget: WebResearchBudget) -> String {
        var context = "<web_evidence untrusted=\"true\">\n"
        for source in sources {
            let candidate = "[source:\(source.id)]\nTitle: \(source.title)\nURL: \(source.url.absoluteString)\nExcerpt: \(source.excerpt)\n[/source:\(source.id)]\n"
            guard context.count + candidate.count <= budget.maximumPromptCharacters else { break }
            context += candidate
        }
        return context + "</web_evidence>"
    }

    private static func safeSourceURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host != "localhost",
              host != "localhost.",
              !host.hasSuffix(".local"),
              !host.contains(":"),
              !isPrivateIPAddress(host)
        else { return nil }
        var cleaned = components
        cleaned.fragment = nil
        return cleaned.url
    }

    private static func isPrivateIPAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10
            || parts[0] == 127
            || (parts[0] == 169 && parts[1] == 254)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168)
    }

    private static func sanitizedTitle(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
    }

    private static func sanitizedExcerpt(_ value: String, limit: Int) -> String? {
        let collapsed = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(limit))
    }
}

private struct BraveContextResponse: Decodable {
    struct Grounding: Decodable {
        struct Generic: Decodable {
            let url: String
            let title: String?
            let snippets: [String]
        }
        let generic: [Generic]
    }
    struct Source: Decodable {
        let title: String?
        let hostname: String?
    }
    let grounding: Grounding
    let sources: [String: Source]
}

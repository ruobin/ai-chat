//
//  Message.swift
//  demo-app
//

import Foundation
import SwiftData

enum MessageRole: String, Codable, CaseIterable {
    case system
    case user
    case assistant
}

@Model
final class Message {
    var id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date
    var conversation: Conversation?
    var webSearchRequested: Bool?
    var webSourcesData: Data?

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = Date()
        self.webSearchRequested = nil
        self.webSourcesData = nil
    }

    var usedWebSearch: Bool { webSearchRequested ?? false }

    var webSources: [PersistedWebSource] {
        guard let webSourcesData,
              let payload = try? JSONDecoder().decode(WebSourcesPayload.self, from: webSourcesData),
              payload.version == 1
        else { return [] }
        return payload.sources
    }

    var citedWebSources: [PersistedWebSource] {
        let citedIDs = Set(
            content.matches(of: /\[source:([0-9]+)\]/)
                .compactMap { Int($0.output.1) }
        )
        let sources = webSources
        return citedIDs.isEmpty ? sources : sources.filter { citedIDs.contains($0.id) }
    }

    func setWebSources(_ sources: [PersistedWebSource]) {
        guard !sources.isEmpty else {
            webSourcesData = nil
            return
        }
        webSourcesData = try? JSONEncoder().encode(WebSourcesPayload(version: 1, sources: sources))
    }
}

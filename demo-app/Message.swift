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

    var role: MessageRole {
        get { MessageRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    init(role: MessageRole, content: String) {
        self.id = UUID()
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = Date()
    }
}
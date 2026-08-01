//
//  Conversation.swift
//  demo-app
//

import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "New chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var sortedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var preview: String {
        sortedMessages.last(where: { $0.role == .user || $0.role == .assistant })?.content
            ?? "No messages yet"
    }
}
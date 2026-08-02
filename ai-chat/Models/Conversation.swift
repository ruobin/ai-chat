//
//  Conversation.swift
//  ai-chat
//

import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date

    /// Per-conversation provider/model override. `nil` means "use whatever
    /// `ChatSettings.shared` is currently set to" — this is the fallback for
    /// every conversation that existed before per-conversation overrides
    /// were introduced, so their behavior is unchanged (they keep tracking
    /// the global default, exactly as before) until a model/provider is
    /// explicitly chosen for them via `ModelProviderPickerSheet`. New
    /// conversations are snapshotted with an explicit override at creation
    /// time (see `init`), so they don't silently follow later global
    /// changes.
    ///
    /// Access via `effectiveBaseURL` / `effectiveModelName` rather than
    /// these directly; use `setProviderOverride(baseURL:model:)` to change
    /// them so both fields update together.
    var baseURLOverride: String?
    var modelNameOverride: String?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "New chat") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        // Snapshot the current global default so this conversation's
        // provider/model is stable even if the user later changes the
        // global default (e.g. from Settings) for future new conversations.
        self.baseURLOverride = ChatSettings.shared.baseURLString
        self.modelNameOverride = ChatSettings.shared.modelName
    }

    /// The provider endpoint this conversation actually sends requests to:
    /// its own override if it has one, otherwise the current global
    /// default from `ChatSettings.shared`.
    var effectiveBaseURL: String {
        baseURLOverride ?? ChatSettings.shared.baseURLString
    }

    /// The model this conversation actually sends requests with: its own
    /// override if it has one, otherwise the current global default from
    /// `ChatSettings.shared`.
    var effectiveModelName: String {
        modelNameOverride ?? ChatSettings.shared.modelName
    }

    /// Sets this conversation's provider/model override. Both fields are
    /// always set together so a conversation never ends up with a base URL
    /// from one provider and a model name from another.
    func setProviderOverride(baseURL: String, model: String) {
        baseURLOverride = baseURL
        modelNameOverride = model
    }

    var sortedMessages: [Message] {
        messages.sorted { $0.createdAt < $1.createdAt }
    }

    var preview: String {
        sortedMessages.last(where: { $0.role == .user || $0.role == .assistant })?.content
            ?? "No messages yet"
    }
}
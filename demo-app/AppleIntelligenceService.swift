//
//  AppleIntelligenceService.swift
//  demo-app
//
//  On-device chat via Apple Intelligence's Foundation Models framework
//  (iOS 26+). No API key, no network — generation runs locally in the
//  system's Apple Intelligence process.
//
//  Unlike the HTTP providers, the on-device model keeps no server-side
//  session, so (mirroring `ChatService`'s stateless contract) each call
//  builds a fresh `LanguageModelSession` seeded with a `Transcript`
//  replayed from the conversation history, then streams the response.
//

import Foundation
import FoundationModels

enum AppleIntelligenceError: LocalizedError {
    case unavailable(String)
    case noUserMessage
    case contextTooLong

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .noUserMessage:
            return "No user message to respond to."
        case .contextTooLong:
            return "This conversation is too long for the on-device model's "
                + "context window. Start a new chat, or switch this "
                + "conversation to a cloud provider."
        }
    }
}

/// Runtime status of the on-device model on this device, mapped from
/// `SystemLanguageModel.Availability`. Displayed in Settings and the
/// per-conversation picker when the Apple Intelligence preset is selected.
enum AppleIntelligenceStatus: Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    /// Human-readable explanation for the unavailable states; `nil` when
    /// the model is ready to use.
    var unavailableMessage: String? {
        switch self {
        case .available:
            return nil
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off. Enable it in "
                + "System Settings > Apple Intelligence."
        case .modelNotReady:
            return "The on-device model is still downloading or preparing. "
                + "Try again shortly."
        }
    }
}

struct AppleIntelligenceService {
    let settings: ChatSettings

    init(settings: ChatSettings = .shared) {
        self.settings = settings
    }

    /// Current availability of the on-device model. Reading this from a
    /// SwiftUI body is observation-tracked (the framework's model object is
    /// `Observable`), so status rows update when a model download finishes.
    static var status: AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            default:
                return .deviceNotEligible
            }
        }
    }

    static var isAvailable: Bool {
        status == .available
    }

    /// Streams a reply from the on-device model. Same contract as
    /// `ChatService.streamCompletion`: `messages` is the full chat history
    /// (system prompt first, ending with the latest user message) and
    /// `onToken` is called on the main actor with incremental deltas.
    func streamCompletion(
        messages: [ProviderChatMessage],
        onToken: @MainActor (String) -> Void
    ) async throws {
        guard Self.isAvailable else {
            throw AppleIntelligenceError.unavailable(
                Self.status.unavailableMessage ?? "Apple Intelligence is unavailable."
            )
        }

        let (transcript, prompt) = try Self.makeTranscript(from: messages)
        let session = LanguageModelSession(transcript: transcript)
        let options = GenerationOptions(temperature: settings.temperature)

        do {
            var emitted = ""
            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                // Snapshots are cumulative; forward only the new suffix as a
                // delta so callers can append like they do for SSE streams.
                let full = snapshot.content
                guard full.count > emitted.count else { continue }
                let delta = String(full.dropFirst(emitted.count))
                emitted = full
                onToken(delta)
            }
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw AppleIntelligenceError.contextTooLong
        }
    }

    /// Converts the provider-style message list into a `Transcript` for
    /// session replay plus the prompt to respond to. The last entry must be
    /// a user message — `ChatDetailView` only starts a stream when that's
    /// the case (send, retry, and regenerate all leave a user message last).
    /// System messages are folded into the session's instructions.
    static func makeTranscript(
        from messages: [ProviderChatMessage]
    ) throws -> (Transcript, String) {
        guard let last = messages.last, last.role == "user" else {
            throw AppleIntelligenceError.noUserMessage
        }

        var entries: [Transcript.Entry] = []
        for message in messages.dropLast() {
            let segment = Transcript.Segment.text(
                Transcript.TextSegment(content: message.content)
            )
            switch message.role {
            case "system":
                entries.append(.instructions(Transcript.Instructions(
                    segments: [segment],
                    toolDefinitions: []
                )))
            case "user":
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case "assistant":
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [segment]
                )))
            default:
                continue
            }
        }
        return (Transcript(entries: entries), last.content)
    }
}

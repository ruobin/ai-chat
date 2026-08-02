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
    /// Apple's safety guardrail rejected the prompt or the response. The
    /// associated flag records whether web evidence was in the prompt: with
    /// search on, most of the prompt is third-party page text, and that is
    /// usually what tripped the filter rather than anything the user typed.
    case safetyBlocked(usedWebSearch: Bool)
    case unsupportedLanguage
    case busy

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
        case .safetyBlocked(let usedWebSearch):
            if usedWebSearch {
                return "Apple Intelligence blocked this response after "
                    + "reading the web results. On-device safety filters "
                    + "screen the search snippets too, so an unrelated page "
                    + "can trigger this. Try again without web search, "
                    + "reword the search, or switch to a cloud provider."
            }
            return "Apple Intelligence declined to answer this one. Its "
                + "on-device safety filters are stricter than the cloud "
                + "providers'. Try rewording, or switch this conversation "
                + "to a cloud provider."
        case .unsupportedLanguage:
            return "Apple Intelligence doesn't support this language yet. "
                + "Switch this conversation to a cloud provider."
        case .busy:
            return "Apple Intelligence is busy. Try again in a moment."
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
    ///
    /// `usedWebSearch` only shapes the error text when a guardrail fires —
    /// Apple screens the whole prompt, so retrieved page content is a far
    /// likelier trigger than the user's own question.
    func streamCompletion(
        messages: [ProviderChatMessage],
        usedWebSearch: Bool = false,
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
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            // Apple's own description here is the bare "Detected content
            // likely to be unsafe", which reads as an accusation aimed at
            // the user. Replace it with something that names the real cause.
            throw AppleIntelligenceError.safetyBlocked(usedWebSearch: usedWebSearch)
        } catch LanguageModelSession.GenerationError.refusal {
            throw AppleIntelligenceError.safetyBlocked(usedWebSearch: usedWebSearch)
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            throw AppleIntelligenceError.unsupportedLanguage
        } catch LanguageModelSession.GenerationError.rateLimited {
            throw AppleIntelligenceError.busy
        } catch LanguageModelSession.GenerationError.concurrentRequests {
            throw AppleIntelligenceError.busy
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

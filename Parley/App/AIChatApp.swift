//
//  AIChatApp.swift
//  Parley
//

import SwiftUI
import SwiftData

@main
struct AIChatApp: App {
    @State private var settings = ChatSettings.shared
    @State private var storeFailure: String?

    private let container: ModelContainer
    /// True when the on-disk store couldn't be opened and we fell back to an
    /// in-memory one, so the UI can warn that this session won't be saved.
    private let isEphemeral: Bool

    init() {
        let schema = Schema([Conversation.self, Message.self])
        let onDisk = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // Previously this was `try! ... else fatalError`, which turns any
        // unreadable store into a crash on launch — the worst possible
        // failure mode, and one that would strand a user (or an App Review
        // tester) with an app that can never start. There's no schema
        // migration plan yet, so an incompatible store left over from an
        // older build is a realistic way to get here.
        //
        // Falling back to an in-memory container keeps the app usable and
        // lets the user copy anything important out, at the cost of not
        // persisting this session. The UI surfaces that clearly rather than
        // silently pretending everything is fine.
        do {
            container = try ModelContainer(for: schema, configurations: [onDisk])
            isEphemeral = false
            _storeFailure = State(initialValue: nil)
        } catch {
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // If even an in-memory store can't be built the process is
            // unrecoverable, and there is nothing left to fall back to.
            container = try! ModelContainer(for: schema, configurations: [inMemory])
            isEphemeral = true
            _storeFailure = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.theme.colorScheme)
                .alert(
                    "Saved chats couldn't be opened",
                    isPresented: .constant(isEphemeral && storeFailure != nil)
                ) {
                    Button("Continue") { storeFailure = nil }
                } message: {
                    Text(
                        "Parley couldn't open its local database, so this "
                        + "session won't be saved. Your existing chats are "
                        + "still on the device. Reinstalling the app clears "
                        + "them permanently.\n\n\(storeFailure ?? "")"
                    )
                }
        }
        .modelContainer(container)
    }
}
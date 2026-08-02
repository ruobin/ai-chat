//
//  AIChatApp.swift
//  ai-chat
//

import SwiftUI
import SwiftData

@main
struct AIChatApp: App {
    @State private var settings = ChatSettings.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Conversation.self,
            Message.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.theme.colorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
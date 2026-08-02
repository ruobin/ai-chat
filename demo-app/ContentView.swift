//
//  ContentView.swift
//  demo-app
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var selection: Conversation?
    @State private var showSettings: Bool = false

    private var settings: ChatSettings { .shared }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            // First-run onboarding: auto-open Settings only when the active
            // provider actually needs a key and doesn't have one. Keyless
            // providers (Apple Intelligence, Ollama, custom) shouldn't be
            // pestered on every launch.
            if !settings.detectedPreset.allowsEmptyKey && !settings.hasAPIKey {
                showSettings = true
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(conversations) { convo in
                NavigationLink(value: convo) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(convo.title)
                            .font(.body)
                            .lineLimit(1)
                        Text(convo.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(convo)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .tag(convo)
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newConversation()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Tap the pencil to start a new chat.")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let conversation = selection {
            ChatDetailView(conversation: conversation)
                .id(conversation.id)
        } else {
            ContentUnavailableView {
                Label("Pick or start a chat", systemImage: "bubble.left")
            } description: {
                Text("Choose a conversation from the sidebar, or start a new one.")
            } actions: {
                Button {
                    newConversation()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func newConversation() {
        let convo = Conversation()
        modelContext.insert(convo)
        try? modelContext.save()
        selection = convo
    }

    private func delete(_ conversation: Conversation) {
        if selection == conversation { selection = nil }
        modelContext.delete(conversation)
        try? modelContext.save()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self, Message.self], inMemory: true)
}

//
//  ChatDetailView.swift
//  demo-app
//

import SwiftUI
import SwiftData

struct ChatDetailView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var modelContext

    @State private var inputText: String = ""
    @State private var streamingContent: String = ""
    @State private var isStreaming: Bool = false
    @State private var errorMessage: String?
    @State private var showModelPicker: Bool = false

    private let service = ChatService()
    private let settings = ChatSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            ChatInputBar(
                text: $inputText,
                isStreaming: isStreaming,
                onSend: send
            )
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showModelPicker = true
                } label: {
                    VStack(spacing: 1) {
                        Text(conversation.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            Text(settings.detectedPreset.label)
                            Text("·")
                            Text(settings.modelName)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Model & provider", systemImage: "cpu")
                    }
                    Button {
                        copyConversation()
                    } label: {
                        Label("Copy conversation", systemImage: "doc.on.doc")
                    }
                    .disabled(conversation.messages.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelProviderPickerSheet()
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if conversation.messages.isEmpty && !isStreaming {
                        EmptyChatHint()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    }
                    ForEach(conversation.sortedMessages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if isStreaming {
                        StreamingBubble(content: streamingContent)
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: conversation.messages.count) { _, _ in
                if let last = conversation.sortedMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if streaming {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        inputText = ""
        errorMessage = nil

        let userMessage = Message(role: .user, content: trimmed)
        userMessage.conversation = conversation
        conversation.messages.append(userMessage)
        conversation.updatedAt = Date()
        if conversation.title == "New chat" {
            conversation.title = String(trimmed.prefix(40))
        }
        try? modelContext.save()

        isStreaming = true
        streamingContent = ""

        Task { @MainActor in
            do {
                let providerMessages = buildProviderMessages()
                try await service.streamCompletion(messages: providerMessages) { token in
                    streamingContent += token
                }
                let assistant = Message(role: .assistant, content: streamingContent)
                assistant.conversation = conversation
                conversation.messages.append(assistant)
                conversation.updatedAt = Date()
                try? modelContext.save()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                let errorMsg = Message(
                    role: .assistant,
                    content: "⚠️ " + ((error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription)
                )
                errorMsg.conversation = conversation
                conversation.messages.append(errorMsg)
                try? modelContext.save()
            }
            isStreaming = false
            streamingContent = ""
        }
    }

    private func buildProviderMessages() -> [ProviderChatMessage] {
        var msgs: [ProviderChatMessage] = []
        let system = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            msgs.append(ProviderChatMessage(role: "system", content: system))
        }
        for msg in conversation.sortedMessages where msg.role != .system {
            msgs.append(ProviderChatMessage(role: msg.role.rawValue, content: msg.content))
        }
        return msgs
    }

    /// Copies the whole conversation to the pasteboard as plain text, one
    /// "Role: content" line per message.
    private func copyConversation() {
        let text = conversation.sortedMessages
            .map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        UIPasteboard.general.string = text
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start the conversation")
                .font(.headline)
            Text("Type a message below to chat with the model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StreamingBubble: View {
    let content: String
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(content.isEmpty ? " " : content)
                    .textSelection(.enabled)
                if content.isEmpty {
                    TypingIndicator()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.12))
            .foregroundStyle(.primary)
            .clipShape(BubbleShape(role: .assistant))
            Spacer(minLength: 40)
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 0.3 : 1.0)
            }
        }
        .foregroundStyle(.secondary)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                phase = 2
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .foregroundStyle(bubbleForeground)
                .clipShape(BubbleShape(role: message.role))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return .accentColor
        default: return Color.secondary.opacity(0.12)
        }
    }

    private var bubbleForeground: Color {
        switch message.role {
        case .user: return .white
        default: return .primary
        }
    }
}

private struct BubbleShape: Shape {
    let role: MessageRole
    func path(in rect: CGRect) -> Path {
        let corners: UIRectCorner = role == .user
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        return Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: 18, height: 18)
        ).cgPath)
    }
}

/// Lightweight sheet for switching provider/model directly from the chat
/// page, without diving into full Settings. Mirrors the provider/model
/// pickers in `SettingsView` but scoped to just those two concerns.
private struct ModelProviderPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ChatSettings.shared
    @State private var preset: ProviderPreset

    @State private var availableModels: [ProviderModel] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchModelsError: String?

    private let service = ChatService()

    init() {
        let s = ChatSettings.shared
        let resolved = ProviderPreset.allCases.first { $0.defaultBaseURL == s.baseURLString } ?? .custom
        _preset = State(initialValue: resolved)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Preset", selection: $preset) {
                        ForEach(ProviderPreset.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .onChange(of: preset) { _, new in
                        if !new.defaultBaseURL.isEmpty {
                            settings.baseURLString = new.defaultBaseURL
                        }
                        if !new.defaultModel.isEmpty {
                            settings.modelName = new.defaultModel
                        }
                        availableModels = []
                        fetchModelsError = nil
                    }
                    if preset == .custom {
                        TextField("Base URL", text: $settings.baseURLString)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    if !settings.hasAPIKey && !preset.allowsEmptyKey {
                        Label("No API key set for this provider. Open full Settings to add one.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("Model name", text: $settings.modelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        Task { await fetchModels() }
                    } label: {
                        if isFetchingModels {
                            HStack {
                                ProgressView()
                                Text("Fetching models…")
                            }
                        } else {
                            Label("Fetch available models", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isFetchingModels)

                    if let fetchModelsError {
                        Text(fetchModelsError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if !availableModels.isEmpty {
                        ForEach(availableModels, id: \.id) { model in
                            Button {
                                settings.modelName = model.id
                            } label: {
                                HStack {
                                    Text(model.id)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if settings.modelName == model.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    } else if !preset.suggestedModels.isEmpty {
                        ForEach(preset.suggestedModels, id: \.self) { model in
                            Button {
                                settings.modelName = model
                            } label: {
                                HStack {
                                    Text(model)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if settings.modelName == model {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Applies to new messages sent in this conversation onward.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Model & Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func fetchModels() async {
        isFetchingModels = true
        fetchModelsError = nil
        defer { isFetchingModels = false }
        do {
            availableModels = try await service.fetchModels()
        } catch {
            availableModels = []
            fetchModelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ChatInputBar: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .disabled(isStreaming)
                .submitLabel(.send)
                .onSubmit(onSend)
            Button(action: onSend) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(isStreaming || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
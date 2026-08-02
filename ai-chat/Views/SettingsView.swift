//
//  SettingsView.swift
//  ai-chat
//

import SwiftUI

struct SettingsView: View {
    enum InitialSection {
        case general
        case webSearch
    }

    @Environment(\.dismiss) private var dismiss

    @State private var settings = ChatSettings.shared
    @State private var preset: ProviderPreset
    @State private var apiKeyInput: String = ""
    @State private var showSaved: Bool = false
    @State private var saveError: String?

    @State private var availableModels: [ProviderModel] = []
    @State private var isFetchingModels: Bool = false
    @State private var fetchModelsError: String?
    @State private var webSearchKeyInput: String = ""
    @State private var webSearchKeyError: String?

    private let service = ChatService()
    private let webSearchSettings = WebSearchSettings.shared
    private let initialSection: InitialSection

    init(initialSection: InitialSection = .general) {
        self.initialSection = initialSection
        let s = ChatSettings.shared
        _preset = State(initialValue: ProviderPreset.detect(from: s.baseURLString))
        _apiKeyInput = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if !preset.isOnDevice {
                    apiKeySection
                }
                providerSection
                modelSection
                systemPromptSection
                temperatureSection
                webSearchSection
                appearanceSection
                supportSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if apiKeyInput.isEmpty, let existing = settings.apiKey {
                    apiKeyInput = existing
                }
                if webSearchKeyInput.isEmpty {
                    webSearchKeyInput = webSearchSettings.key() ?? ""
                }
            }
            .onChange(of: settings.baseURLString) { _, _ in
                loadAPIKeyForActiveProvider()
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            SecureField("API key", text: $apiKeyInput)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
            Button {
                saveAPIKey()
            } label: {
                Label("Save API key", systemImage: "key.fill")
            }
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            if settings.hasAPIKey {
                Button(role: .destructive) {
                    apiKeyInput = ""
                    try? settings.setAPIKey(nil)
                    showSaved = true
                } label: {
                    Label("Remove saved key", systemImage: "trash")
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("BYOK — API Key for \(settings.detectedPreset.label)")
        } footer: {
            Text("Stored securely in the iOS Keychain, scoped to this provider's endpoint — each provider keeps its own key, so switching providers won't overwrite or reuse another provider's key. Optional for local providers like Ollama. The key is sent only as the Authorization header on requests to your chosen provider.")
                .font(.footnote)
        }
    }

    private var providerSection: some View {
        Section {
            Picker("Preset", selection: $preset) {
                ForEach(ProviderPreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .onChange(of: preset) { _, new in
                settings.applyPreset(new)
            }
            if preset.isOnDevice {
                // On-device model: no endpoint to edit — show whether this
                // device can actually run it instead.
                if let message = AppleIntelligenceService.status.unavailableMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Label("On-device model ready.", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            } else {
                TextField("Base URL", text: $settings.baseURLString)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            if let note = preset.infoNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if preset == .custom {
                Button {
                    preset = .custom
                    settings.baseURLString = ""
                    settings.modelName = ""
                } label: {
                    Label("Clear custom endpoint", systemImage: "xmark.circle")
                }
                .disabled(settings.baseURLString.isEmpty && settings.modelName.isEmpty)
            }
        } header: {
            Text("Provider")
        } footer: {
            Text("This is the default provider for new conversations. Change an individual conversation's provider from its own model picker without affecting this default.")
                .font(.footnote)
        }
    }

    private var modelSection: some View {
        Section {
            if !preset.isOnDevice {
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
                    Picker("Available models", selection: Binding(
                        get: { settings.modelName },
                        set: { settings.modelName = $0 }
                    )) {
                        ForEach(availableModels) { model in
                            Text(model.id).tag(model.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                if !preset.suggestedModels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(preset.suggestedModels, id: \.self) { model in
                                Button {
                                    settings.modelName = model
                                } label: {
                                    Text(model)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule().fill(
                                                settings.modelName == model
                                                    ? Color.accentColor.opacity(0.2)
                                                    : Color.secondary.opacity(0.12)
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            if preset.isOnDevice {
                Text("Apple Intelligence has a single built-in model — nothing to choose here.")
                    .font(.footnote)
            } else {
                Text("Fetch the live list from your provider, tap a suggestion, or type your own model name. This is the default used for new conversations — existing conversations keep whatever model they were started with (or last switched to individually) unless you change it from within that conversation.")
                    .font(.footnote)
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

    private var systemPromptSection: some View {
        Section("System prompt") {
            TextField("You are a helpful assistant.", text: $settings.systemPrompt, axis: .vertical)
                .lineLimit(2...8)
        }
    }

    private var temperatureSection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(settings.temperature, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.temperature, in: 0...2, step: 0.05)
                    .disabled(!ChatService.modelSupportsCustomTemperature(settings.modelName))
            }
        } footer: {
            if ChatService.modelSupportsCustomTemperature(settings.modelName) {
                Text("Lower values are more deterministic, higher values more creative.")
                    .font(.footnote)
            } else {
                Text("This model only supports the default temperature. This setting is ignored for reasoning models (o1/o3/o4-mini, gpt-5 and later).")
                    .font(.footnote)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Label(theme.label, systemImage: theme.icon).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var webSearchSection: some View {
        Section {
            SecureField("Brave Search API key", text: $webSearchKeyInput)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                saveWebSearchKey()
            } label: {
                Label("Save Brave Search key", systemImage: "key.fill")
            }
            .disabled(webSearchKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if webSearchSettings.hasKey {
                Button(role: .destructive) {
                    webSearchKeyInput = ""
                    try? webSearchSettings.setKey(nil)
                } label: {
                    Label("Remove Brave Search key", systemImage: "trash")
                }
            }
            if let webSearchKeyError {
                Text(webSearchKeyError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Link("Get a Brave Search API key", destination: URL(string: "https://api.search.brave.com/")!)
            Link("Brave Search privacy notice", destination: URL(string: "https://api-dashboard.search.brave.com/documentation/resources/privacy-notice")!)
        } header: {
            Text("Web Search")
        } footer: {
            Text("When enabled per message, the current message is sent to Brave Search. Brave documents query retention of up to 90 days. Search results are untrusted; LLM Context has no documented safe-search control.")
                .font(.footnote)
        }
        .id(initialSection == .webSearch ? "web-search" : "web-search-general")
    }

    /// Contact and policy links. App Review Guideline 1.5 requires reachable
    /// contact info, and 5.1.1(i) requires the privacy policy to be
    /// accessible from inside the app, not only in App Store Connect.
    /// Hidden entirely until `SupportInfo` is filled in, so a build with
    /// placeholders never ships dead links.
    @ViewBuilder
    private var supportSection: some View {
        if SupportInfo.isConfigured {
            Section {
                Link(destination: SupportInfo.privacyPolicyURL) {
                    Label("Privacy policy", systemImage: "hand.raised")
                }
                Link(destination: SupportInfo.supportURL) {
                    Label("Support", systemImage: "lifepreserver")
                }
                if let mailto = URL(string: "mailto:\(SupportInfo.contactEmail)") {
                    Link(destination: mailto) {
                        Label(SupportInfo.contactEmail, systemImage: "envelope")
                    }
                }
            } header: {
                Text("Support")
            } footer: {
                Text("Responses are generated by the AI provider you choose "
                     + "and may be inaccurate or objectionable. Touch and hold "
                     + "any reply to report it.")
                    .font(.footnote)
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Provider") {
                Text(settings.detectedPreset.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Endpoint") {
                Text(settings.detectedPreset.isOnDevice
                     ? "On-device — no network"
                     : settings.baseURLString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Model") {
                Text(settings.modelName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !settings.detectedPreset.isOnDevice {
                LabeledContent("Keychain entry") {
                    Text(settings.hasAPIKey ? "Saved" : "Not set")
                        .font(.footnote)
                        .foregroundStyle(settings.hasAPIKey ? .green : .secondary)
                }
            }
        } header: {
            Text("Default for new conversations")
        }
    }

    private func saveAPIKey() {
        do {
            try settings.setAPIKey(apiKeyInput)
            saveError = nil
            showSaved = true
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveWebSearchKey() {
        do {
            try webSearchSettings.setKey(webSearchKeyInput)
            webSearchKeyError = nil
        } catch {
            webSearchKeyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Reloads the key field to reflect whichever provider is now active,
    /// since each provider's key is stored independently. Called whenever
    /// the base URL changes (preset switch or manual edit).
    private func loadAPIKeyForActiveProvider() {
        apiKeyInput = settings.apiKey ?? ""
        saveError = nil
    }
}

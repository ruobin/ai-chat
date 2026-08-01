//
//  SettingsView.swift
//  demo-app
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var settings = ChatSettings.shared
    @State private var preset: ProviderPreset
    @State private var apiKeyInput: String = ""
    @State private var showSaved: Bool = false
    @State private var saveError: String?

    init() {
        let s = ChatSettings.shared
        let resolved = ProviderPreset.allCases.first { preset in
            preset.defaultBaseURL == s.baseURLString
        } ?? .custom
        _preset = State(initialValue: resolved)
        _apiKeyInput = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                providerSection
                modelSection
                systemPromptSection
                temperatureSection
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
            Text("BYOK — API Key")
        } footer: {
            Text("Stored securely in the iOS Keychain. Optional for local providers like Ollama. The key is sent only as the Authorization header on requests to your chosen provider.")
                .font(.footnote)
        }
    }

    private var providerSection: some View {
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
            }
            TextField("Base URL", text: $settings.baseURLString)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
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
        }
    }

    private var modelSection: some View {
        Section {
            TextField("Model name", text: $settings.modelName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
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
        } header: {
            Text("Model")
        } footer: {
            Text("Tap a suggestion to fill the model field, or type your own.")
                .font(.footnote)
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
            }
        } footer: {
            Text("Lower values are more deterministic, higher values more creative.")
                .font(.footnote)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Provider") {
                Text(settings.detectedPreset.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Endpoint") {
                Text(settings.baseURLString)
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
            LabeledContent("Keychain entry") {
                Text(settings.hasAPIKey ? "Saved" : "Not set")
                    .font(.footnote)
                    .foregroundStyle(settings.hasAPIKey ? .green : .secondary)
            }
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
}
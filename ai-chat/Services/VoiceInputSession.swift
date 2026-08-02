//
//  VoiceInputSession.swift
//  ai-chat
//
//  Live, entirely on-device transcription via SpeechAnalyzer.
//

import AVFAudio
import Foundation
import Speech

enum VoicePreparation: Equatable {
    case requestingPermission
    case resolvingLocale
    case downloadingModel(progress: Double?)
    case configuringAudio

    var message: String {
        switch self {
        case .requestingPermission:
            return "Requesting microphone access…"
        case .resolvingLocale:
            return "Preparing on-device transcription…"
        case .downloadingModel(let progress):
            if let progress {
                return "Downloading speech model… \(Int(progress * 100))%"
            }
            return "Downloading speech model…"
        case .configuringAudio:
            return "Preparing microphone…"
        }
    }
}

enum VoiceInputState: Equatable {
    case idle
    case preparing(VoicePreparation)
    case recording
    case finalizing
    case unavailable(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .finalizing:
            return true
        case .idle, .unavailable, .failed:
            return false
        }
    }

    var blocksEditing: Bool { isActive }
    var blocksSending: Bool { isActive }

    var statusMessage: String? {
        switch self {
        case .idle:
            return nil
        case .preparing(let preparation):
            return preparation.message
        case .recording:
            return "Listening…"
        case .finalizing:
            return "Finishing transcription…"
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    var permanentlyUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

enum VoiceDraftComposer {
    static func combine(base: String, utterance: String) -> String {
        guard !utterance.isEmpty else { return base }
        guard !base.isEmpty else { return utterance }
        if base.last?.isWhitespace == true || utterance.first?.isWhitespace == true {
            return base + utterance
        }
        return base + " " + utterance
    }
}

struct VoiceTranscriptAccumulator {
    private(set) var finalized = ""
    private(set) var volatile = ""

    var transcript: String {
        VoiceDraftComposer.combine(base: finalized, utterance: volatile)
    }

    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = VoiceDraftComposer.combine(base: finalized, utterance: text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    mutating func reset() {
        finalized = ""
        volatile = ""
    }
}

enum VoiceInputError: LocalizedError {
    case microphoneDenied
    case transcriberUnavailable
    case unsupportedLocale
    case unsupportedModel
    case modelUnavailable
    case modelReservationUnavailable
    case noAudioFormat
    case noMicrophone
    case audioConversion
    case interrupted

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Enable it for Parley in Settings and try again."
        case .transcriberUnavailable:
            return "On-device transcription isn't supported on this device."
        case .unsupportedLocale:
            return "On-device transcription isn't available for your current language."
        case .unsupportedModel:
            return "An on-device speech model isn't available for your current language."
        case .modelUnavailable:
            return "The on-device speech model isn't available. Connect to the internet and try again."
        case .modelReservationUnavailable:
            return "The device can't reserve another on-device speech language. Remove an unused speech language and try again."
        case .noAudioFormat:
            return "The on-device speech model isn't ready for audio input."
        case .noMicrophone:
            return "No microphone input is available."
        case .audioConversion:
            return "The microphone audio couldn't be prepared for transcription."
        case .interrupted:
            return "Voice input stopped because microphone access was interrupted."
        }
    }

    var isPermanent: Bool {
        switch self {
        case .transcriberUnavailable, .unsupportedLocale, .unsupportedModel,
                .modelReservationUnavailable:
            return true
        default:
            return false
        }
    }
}

@MainActor @Observable
final class VoiceInputSession {
    private(set) var state: VoiceInputState = .idle
    private(set) var transcript = ""

    private var accumulator = VoiceTranscriptAccumulator()
    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var analyzerInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?
    private var operationTask: Task<Void, Error>?
    private var operationID: UUID?
    private var inputTapInstalled = false

    func start() async {
        guard !Task.isCancelled, !state.isActive else { return }

        await cancel()
        guard !Task.isCancelled else { return }
        transcript = ""
        accumulator.reset()

        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await prepareAndStart()
        }
        operationTask = task
        operationID = identifier

        do {
            try await task.value
            guard operationID == identifier else { return }
            operationTask = nil
            operationID = nil
        } catch is CancellationError {
            guard operationID == identifier else { return }
            operationTask = nil
            operationID = nil
            if state.isActive {
                await tearDown(cancelAnalyzer: true, clearTranscript: true)
                state = .idle
            }
        } catch {
            guard operationID == identifier else { return }
            operationTask = nil
            operationID = nil
            await fail(with: error)
        }
    }

    func finish() async {
        guard state == .recording else { return }
        state = .finalizing
        stopAudioCapture()
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
            await resultTask?.value
            if case .failed = state { return }
            if case .unavailable = state { return }
            await tearDown(cancelAnalyzer: false, clearTranscript: false)
            state = .idle
        } catch is CancellationError {
            await tearDown(cancelAnalyzer: true, clearTranscript: true)
            state = .idle
        } catch {
            await fail(with: error)
        }
    }

    func cancel() async {
        operationTask?.cancel()
        operationTask = nil
        operationID = nil
        await tearDown(cancelAnalyzer: true, clearTranscript: true)
        state = .idle
    }

    private func prepareAndStart() async throws {
        state = .preparing(.requestingPermission)
        try await requestMicrophonePermission()
        try Task.checkCancellation()

        guard SpeechTranscriber.isAvailable else {
            throw VoiceInputError.transcriberUnavailable
        }

        state = .preparing(.resolvingLocale)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw VoiceInputError.unsupportedLocale
        }
        try Task.checkCancellation()

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        let modules: [any SpeechModule] = [transcriber]
        try await prepareAssets(for: modules, locale: locale)
        try Task.checkCancellation()

        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw VoiceInputError.noAudioFormat
        }

        state = .preparing(.configuringAudio)
        try await configurePipeline(transcriber: transcriber, modules: modules, analysisFormat: analysisFormat)
        state = .recording
    }

    private func requestMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw VoiceInputError.microphoneDenied
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                throw VoiceInputError.microphoneDenied
            }
        @unknown default:
            throw VoiceInputError.microphoneDenied
        }
    }

    private func prepareAssets(
        for modules: [any SpeechModule],
        locale: Locale
    ) async throws {
        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            break
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw VoiceInputError.modelUnavailable
            }
            state = .preparing(.downloadingModel(progress: request.progress.fractionCompleted))
            let progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let progress = request.progress.fractionCompleted
                    self?.state = .preparing(.downloadingModel(
                        progress: progress.isFinite ? min(max(progress, 0), 1) : nil
                    ))
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            defer { progressTask.cancel() }
            try await request.downloadAndInstall()
        case .unsupported:
            throw VoiceInputError.unsupportedModel
        @unknown default:
            throw VoiceInputError.modelUnavailable
        }

        let reserved = await AssetInventory.reservedLocales
        let alreadyReserved = reserved.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        if !alreadyReserved {
            guard try await AssetInventory.reserve(locale: locale) else {
                throw VoiceInputError.modelReservationUnavailable
            }
        }
    }

    private func configurePipeline(
        transcriber: SpeechTranscriber,
        modules: [any SpeechModule],
        analysisFormat: AVAudioFormat
    ) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceInputError.noMicrophone
        }
        guard let converter = AudioBufferConverter(from: inputFormat, to: analysisFormat) else {
            throw VoiceInputError.audioConversion
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: analysisFormat)

        self.audioEngine = engine
        self.analyzer = analyzer
        analyzerInputContinuation = continuation

        resultTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    accumulator.apply(text, isFinal: result.isFinal)
                    transcript = accumulator.transcript
                }
            } catch is CancellationError {
            } catch {
                await self?.failFromPipeline(with: error)
            }
        }

        analysisTask = Task { @MainActor [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
            } catch {
                await self?.failFromPipeline(with: error)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            do {
                let converted = try converter.convert(buffer)
                continuation.yield(AnalyzerInput(buffer: converted))
            } catch {
                Task { @MainActor [weak self] in
                    await self?.failFromPipeline(with: VoiceInputError.audioConversion)
                }
            }
        }
        inputTapInstalled = true

        engine.prepare()
        try engine.start()
        observeAudioInterruptions()
    }

    private func observeAudioInterruptions() {
        interruptionTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification
            ) {
                guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                      type == .began
                else { continue }
                await self?.failFromPipeline(with: VoiceInputError.interrupted)
            }
        }
        routeChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification
            ) {
                guard AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty else {
                    continue
                }
                await self?.failFromPipeline(with: VoiceInputError.noMicrophone)
            }
        }
    }

    private func failFromPipeline(with error: Error) async {
        guard state.isActive else { return }
        await fail(with: error)
    }

    private func fail(with error: Error) async {
        await tearDown(cancelAnalyzer: true, clearTranscript: true)
        let message = (error as? LocalizedError)?.errorDescription
            ?? "Voice transcription failed. Please try again."
        if (error as? VoiceInputError)?.isPermanent == true {
            state = .unavailable(message)
        } else {
            state = .failed(message)
        }
    }

    private func tearDown(cancelAnalyzer: Bool, clearTranscript: Bool) async {
        stopAudioCapture()
        analyzerInputContinuation?.finish()
        analyzerInputContinuation = nil

        if cancelAnalyzer {
            await analyzer?.cancelAndFinishNow()
        }
        analysisTask?.cancel()
        resultTask?.cancel()
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
        analysisTask = nil
        resultTask = nil
        interruptionTask = nil
        routeChangeTask = nil
        analyzer = nil
        audioEngine = nil

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )

        if clearTranscript {
            accumulator.reset()
            transcript = ""
        }
    }

    private func stopAudioCapture() {
        guard let audioEngine else { return }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        audioEngine.stop()
    }
}

private final class AudioBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        lock.lock()
        defer { lock.unlock() }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            throw VoiceInputError.audioConversion
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) {
            _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        guard status != .error, conversionError == nil else {
            throw conversionError ?? VoiceInputError.audioConversion
        }
        return output
    }
}

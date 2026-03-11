@preconcurrency import AVFoundation
import Foundation
import MoonshineVoice
import VoceKit

/// Manages live microphone capture and streaming Moonshine transcription.
///
/// This intentionally stays close to Moonshine's upstream `MicTranscriber`
/// flow: each captured mic buffer is converted immediately and fed to the
/// stream without an intermediate batching timer.
final class MoonshineStreamingSession: @unchecked Sendable {
    struct Configuration: Sendable {
        var modelDirectoryPath: String
        var modelArch: MoonshineModelPreset
    }

    private let config: Configuration
    private let onPartialText: @Sendable (String) -> Void

    // Accessed only on processingQueue.
    private let processingQueue = DispatchQueue(label: "voce.moonshine-stream", qos: .userInitiated)
    private var stream: MoonshineVoice.Stream?
    private var latestTranscript: Transcript = .init()
    private var latestStreamError: Error?
    private var isStopped = false

    // Accessed on main thread.
    private var audioEngine: AVAudioEngine?

    init(config: Configuration, onPartialText: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.onPartialText = onPartialText
    }

    /// Starts audio capture and streaming transcription.
    /// Must be called from the main thread.
    func start() throws {
        try ensureMicrophonePermission()

        try processingQueue.sync {
            let transcriber = try MoonshineTranscriberCache.shared.transcriber(for: config)
            let stream = try transcriber.createStream(updateInterval: 0.3)
            stream.addListener { [weak self] event in
                self?.handle(event: event)
            }
            try stream.start()

            self.stream = stream
            self.latestTranscript = .init()
            self.latestStreamError = nil
            self.isStopped = false
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Let Moonshine handle resampling internally. The probe showed our
        // app-side 24 kHz -> 16 kHz conversion path crushes AirPods input
        // amplitude, while the raw float samples are healthy.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MoonshineTranscriptionError.unsupportedAudioFormat
        }

        let needsConversion = inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount
            || inputFormat.commonFormat != targetFormat.commonFormat
        let converter = needsConversion ? AVAudioConverter(from: inputFormat, to: targetFormat) : nil

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let converted = self.convertBuffer(
                buffer,
                converter: converter,
                inputFormat: inputFormat,
                targetFormat: targetFormat
            )
            guard !converted.samples.isEmpty else { return }

            self.processingQueue.async { [weak self] in
                guard let self, !self.isStopped else { return }

                do {
                    try self.stream?.addAudio(
                        converted.samples,
                        sampleRate: Int32(converted.sampleRate.rounded())
                    )
                } catch {
                    self.latestStreamError = error
                }
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            processingQueue.sync {
                stream?.close()
                stream = nil
                latestTranscript = .init()
                latestStreamError = nil
                isStopped = true
            }
            throw error
        }

        audioEngine = engine
    }

    /// Stops capture, finalises the transcript, and returns the result.
    /// Must be called from the main thread.
    func stop() throws -> RawTranscript {
        tearDownAudio()

        return try processingQueue.sync {
            defer {
                stream?.close()
                stream = nil
                latestTranscript = .init()
                latestStreamError = nil
                isStopped = true
            }

            try stream?.stop()

            let finalTranscript = try stream?.updateTranscription(
                flags: TranscribeStreamFlags.flagForceUpdate
            ) ?? latestTranscript
            latestTranscript = finalTranscript

            if finalTranscript.lines.isEmpty, let latestStreamError {
                throw latestStreamError
            }

            let rawTranscript = Self.buildRawTranscript(from: finalTranscript)
            if rawTranscript.text.isEmpty {
                throw MoonshineTranscriptionError.emptyLiveTranscript
            }

            return rawTranscript
        }
    }

    /// Cancels without producing a transcript.
    func cancel() {
        tearDownAudio()
        processingQueue.sync {
            isStopped = true
            stream?.close()
            stream = nil
            latestTranscript = .init()
            latestStreamError = nil
        }
    }

    private func handle(event: TranscriptEvent) {
        if let transcriptError = event as? TranscriptError {
            latestStreamError = transcriptError.error
            return
        }

        let currentText = event.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentText.isEmpty else { return }

        let mergedLines = latestTranscript.lines
            .filter { $0.lineId != event.line.lineId } + [event.line]
        let orderedLines = mergedLines.sorted {
            if $0.startTime == $1.startTime {
                return $0.lineId < $1.lineId
            }
            return $0.startTime < $1.startTime
        }
        latestTranscript = Transcript(lines: orderedLines)

        let mergedText = orderedLines
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mergedText.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onPartialText(mergedText)
        }
    }

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat
    ) -> (samples: [Float], sampleRate: Double) {
        final class ConversionState: @unchecked Sendable {
            var didSupplyInput = false
        }

        guard let converter else {
            guard let channelData = buffer.floatChannelData?[0] else {
                return ([], inputFormat.sampleRate)
            }

            let samples = Array(
                UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
            )
            return (samples, inputFormat.sampleRate)
        }

        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
        ) + 256
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return ([], targetFormat.sampleRate)
        }

        let state = ConversionState()
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if state.didSupplyInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            state.didSupplyInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        guard error == nil, let channelData = convertedBuffer.floatChannelData?[0] else {
            return ([], targetFormat.sampleRate)
        }

        let samples = Array(
            UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength))
        )
        return (samples, targetFormat.sampleRate)
    }

    private func tearDownAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    private static func buildRawTranscript(from transcript: Transcript) -> RawTranscript {
        let segments = transcript.lines.map { line in
            TranscriptSegment(
                startMS: Int(line.startTime * 1_000),
                endMS: Int((line.startTime + line.duration) * 1_000),
                text: line.text
            )
        }

        let text = transcript.lines
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let durationMS = Int(
            (transcript.lines.last.map { $0.startTime + $0.duration } ?? 0) * 1_000
        )
        return RawTranscript(text: text, segments: segments, durationMS: durationMS)
    }

    private func ensureMicrophonePermission() throws {
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if permissionStatus == .denied {
            throw MoonshineTranscriptionError.microphonePermissionDenied
        }

        if permissionStatus == .notDetermined {
            var permissionGranted = false
            let semaphore = DispatchSemaphore(value: 0)

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                permissionGranted = granted
                semaphore.signal()
            }

            semaphore.wait()

            if !permissionGranted {
                throw MoonshineTranscriptionError.microphonePermissionDenied
            }
        }
    }
}

import Foundation
import MoonshineVoice

/// Keeps the active Moonshine transcriber warm between dictation sessions so
/// recording startup does not need to reload model weights every time.
final class MoonshineTranscriberCache: @unchecked Sendable {
    static let shared = MoonshineTranscriberCache()

    private struct Key: Equatable {
        let modelDirectoryPath: String
        let modelArch: MoonshineModelPreset
    }

    private let queue = DispatchQueue(label: "voce.moonshine-transcriber-cache", qos: .userInitiated)
    private var cachedKey: Key?
    private var cachedTranscriber: Transcriber?

    private init() {}

    func warm(config: MoonshineStreamingSession.Configuration) {
        let key = Key(modelDirectoryPath: config.modelDirectoryPath, modelArch: config.modelArch)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.prepareTranscriber(for: key)
            } catch {
                // Warm-up is best-effort. Startup will surface the real error if the
                // model cannot be loaded when recording begins.
            }
        }
    }

    func transcriber(for config: MoonshineStreamingSession.Configuration) throws -> Transcriber {
        let key = Key(modelDirectoryPath: config.modelDirectoryPath, modelArch: config.modelArch)
        return try queue.sync {
            try prepareTranscriber(for: key)
        }
    }

    func invalidate() {
        queue.sync {
            cachedTranscriber?.close()
            cachedTranscriber = nil
            cachedKey = nil
        }
    }

    private func prepareTranscriber(for key: Key) throws -> Transcriber {
        if cachedKey == key, let cachedTranscriber {
            return cachedTranscriber
        }

        cachedTranscriber?.close()
        let transcriber = try Transcriber(
            modelPath: key.modelDirectoryPath,
            modelArch: key.modelArch.moonshineArch
        )
        cachedKey = key
        cachedTranscriber = transcriber
        return transcriber
    }
}

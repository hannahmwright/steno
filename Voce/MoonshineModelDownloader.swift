import Foundation

/// Downloads Moonshine model files from the official CDN.
///
/// Each model preset consists of several `.ort` files plus a tokenizer and config.
/// Files are downloaded individually to `~/Library/Application Support/Voce/MoonshineModels/<preset>/`.
@MainActor
final class MoonshineModelDownloader: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(fileIndex: Int, fileCount: Int, fileProgress: Double)
        case completed
        case failed(String)
    }

    @Published var status: Status = .idle

    private var downloadTask: Task<Void, Never>?

    /// Overall progress from 0.0 to 1.0 across all files.
    var overallProgress: Double {
        switch status {
        case .downloading(let fileIndex, let fileCount, let fileProgress):
            guard fileCount > 0 else { return 0 }
            return (Double(fileIndex) + fileProgress) / Double(fileCount)
        case .completed:
            return 1.0
        default:
            return 0
        }
    }

    /// Returns true when the given preset has all required files on disk.
    static func isModelReady(preset: MoonshineModelPreset) -> Bool {
        let path = MoonshineModelPaths.defaultModelDirectoryPath(for: preset)
        return MoonshineModelPaths.missingFiles(in: path, preset: preset).isEmpty
    }

    /// Downloads any missing files for the given preset. Skips files already on disk.
    func download(preset: MoonshineModelPreset) {
        downloadTask?.cancel()
        downloadTask = Task {
            await performDownload(preset: preset)
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        status = .idle
    }

    private nonisolated func performDownload(preset: MoonshineModelPreset) async {
        let destinationDir = MoonshineModelPaths.defaultModelDirectoryPath(for: preset)
        let destinationURL = URL(fileURLWithPath: destinationDir, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            await MainActor.run { status = .failed("Failed to create model directory: \(error.localizedDescription)") }
            return
        }

        let missing = MoonshineModelPaths.missingFiles(in: destinationDir, preset: preset)
        guard !missing.isEmpty else {
            await MainActor.run { status = .completed }
            return
        }

        let baseURL = Self.cdnBaseURL(for: preset)

        for (index, fileName) in missing.enumerated() {
            if Task.isCancelled { await MainActor.run { status = .idle }; return }

            await MainActor.run {
                status = .downloading(fileIndex: index, fileCount: missing.count, fileProgress: 0)
            }

            let remoteURL = baseURL.appendingPathComponent(fileName)
            let localURL = destinationURL.appendingPathComponent(fileName)

            do {
                try await downloadFileWithRetry(
                    from: remoteURL, to: localURL,
                    fileIndex: index, fileCount: missing.count,
                    maxRetries: 3
                )
            } catch is CancellationError {
                await MainActor.run { status = .idle }
                return
            } catch {
                await MainActor.run { status = .failed("Failed to download \(fileName): \(error.localizedDescription)") }
                return
            }
        }

        await MainActor.run { status = .completed }
    }

    private nonisolated func downloadFileWithRetry(
        from remoteURL: URL,
        to localURL: URL,
        fileIndex: Int,
        fileCount: Int,
        maxRetries: Int
    ) async throws {
        var lastError: Error?
        for attempt in 0...maxRetries {
            if attempt > 0 {
                // Wait before retrying: 2s, 4s, 8s
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                await MainActor.run {
                    status = .downloading(fileIndex: fileIndex, fileCount: fileCount, fileProgress: 0)
                }
            }
            do {
                try await downloadFile(from: remoteURL, to: localURL, fileIndex: fileIndex, fileCount: fileCount)
                return // success
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }

    private nonisolated func downloadFile(
        from remoteURL: URL,
        to localURL: URL,
        fileIndex: Int,
        fileCount: Int
    ) async throws {
        let delegate = DownloadDelegate()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300   // 5 min per stalled connection
        config.timeoutIntervalForResource = 3600 // 1 hour total per file
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let task = session.downloadTask(with: remoteURL)

        // Report progress from delegate, throttled to 10Hz
        delegate.onProgress = { @Sendable progress in
            Task { @MainActor [weak self] in
                self?.status = .downloading(fileIndex: fileIndex, fileCount: fileCount, fileProgress: progress)
            }
        }

        // Use a continuation to bridge the delegate-based API
        let tempDownloadURL: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { result in
                continuation.resume(with: result)
            }
            task.resume()
        }

        session.finishTasksAndInvalidate()

        try Task.checkCancellation()

        let tempURL = localURL.appendingPathExtension("download")

        // Move the URLSession temp file to our staging location.
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: tempDownloadURL, to: tempURL)

        // Atomic move into place.
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    private nonisolated static func cdnBaseURL(for preset: MoonshineModelPreset) -> URL {
        URL(string: "https://download.moonshine.ai/model/\(preset.directoryName)/quantized/")!
    }

    private enum DownloadError: LocalizedError {
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Server returned HTTP \(code)"
            }
        }
    }
}

/// Delegate that tracks download progress and completion via a continuation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastReportedTime: CFAbsoluteTime = 0
    var completion: ((Result<URL, Error>) -> Void)?
    var onProgress: (@Sendable (Double) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let shouldReport = now - lastReportedTime >= 0.1
        if shouldReport { lastReportedTime = now }
        lock.unlock()

        if shouldReport {
            let progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)
            onProgress?(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Copy the file before URLSession deletes it
        let safeCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".download")
        do {
            try FileManager.default.copyItem(at: location, to: safeCopy)

            if let httpResponse = downloadTask.response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                try? FileManager.default.removeItem(at: safeCopy)
                completion?(.failure(DownloadError.httpError(httpResponse.statusCode)))
            } else {
                completion?(.success(safeCopy))
            }
        } catch {
            completion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completion?(.failure(error))
        }
    }

    private enum DownloadError: LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(let code): return "Server returned HTTP \(code)"
            }
        }
    }
}

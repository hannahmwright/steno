import Foundation

public enum SessionCoordinatorError: Error, LocalizedError {
    case sessionNotFound

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found"
        }
    }
}

public actor SessionCoordinator {
    private struct ActiveSession: Sendable {
        var appContext: AppContext
        var startedAt: Date
    }

    private struct CleanupExecutionResult: Sendable {
        var transcript: CleanTranscript
        var outcome: CleanupOutcome
    }

    private let captureService: AudioCaptureService
    private let transcriptionEngine: TranscriptionEngine
    private let cleanupEngine: CleanupEngine
    private let fallbackCleanupEngine: CleanupEngine
    private let insertionService: InsertionServiceProtocol
    private let historyStore: HistoryStoreProtocol
    private let lexiconService: PersonalLexiconService
    private let styleProfileService: StyleProfileService
    private let snippetService: SnippetService
    private let voiceCommandService: VoiceCommandService
    private let learningEngine: LearningEngine?

    private var activeSessions: [SessionID: ActiveSession] = [:]
    private(set) var isHandsFreeEnabled: Bool = false

    public init(
        captureService: AudioCaptureService,
        transcriptionEngine: TranscriptionEngine,
        cleanupEngine: CleanupEngine,
        insertionService: InsertionServiceProtocol,
        historyStore: HistoryStoreProtocol,
        lexiconService: PersonalLexiconService,
        styleProfileService: StyleProfileService,
        snippetService: SnippetService = SnippetService(),
        voiceCommandService: VoiceCommandService = VoiceCommandService(),
        fallbackCleanupEngine: CleanupEngine = RuleBasedCleanupEngine(),
        learningEngine: LearningEngine? = nil
    ) {
        self.captureService = captureService
        self.transcriptionEngine = transcriptionEngine
        self.cleanupEngine = cleanupEngine
        self.insertionService = insertionService
        self.historyStore = historyStore
        self.lexiconService = lexiconService
        self.styleProfileService = styleProfileService
        self.snippetService = snippetService
        self.voiceCommandService = voiceCommandService
        self.fallbackCleanupEngine = fallbackCleanupEngine
        self.learningEngine = learningEngine
    }

    @discardableResult
    public func startPressToTalk(appContext: AppContext) async throws -> SessionID {
        let sessionID = SessionID()
        try await captureService.beginCapture(sessionID: sessionID)
        activeSessions[sessionID] = ActiveSession(appContext: appContext, startedAt: Date())
        return sessionID
    }

    /// Registers a session for streaming transcription (audio capture managed externally).
    public func registerStreamingSession(appContext: AppContext) -> SessionID {
        let sessionID = SessionID()
        activeSessions[sessionID] = ActiveSession(appContext: appContext, startedAt: Date())
        return sessionID
    }

    public func stopPressToTalk(sessionID: SessionID, languageHints: [String] = ["en-US"]) async throws -> InsertResult {
        // Remove session before the first await so actor reentrancy cannot process
        // the same session twice while transcription/cleanup are in flight.
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }

        let audioURL = try await captureService.endCapture(sessionID: sessionID)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let rawTranscript = try await transcriptionEngine.transcribe(audioURL: audioURL, languageHints: languageHints)

        return try await finaliseTranscript(rawTranscript, active: active)
    }

    /// Accepts a pre-built transcript (e.g. from streaming) and runs cleanup, insertion, and history.
    public func processStreamingTranscript(
        _ rawTranscript: RawTranscript,
        sessionID: SessionID
    ) async throws -> InsertResult {
        guard let active = activeSessions.removeValue(forKey: sessionID) else {
            throw SessionCoordinatorError.sessionNotFound
        }
        return try await finaliseTranscript(rawTranscript, active: active)
    }

    private func finaliseTranscript(_ raw: RawTranscript, active: ActiveSession) async throws -> InsertResult {
        var rawTranscript = raw
        rawTranscript.text = await snippetService.apply(to: rawTranscript.text, appContext: active.appContext)

        let profile = await styleProfileService.resolve(for: active.appContext)
        let lexicon = await lexiconService.snapshot(for: active.appContext)

        let cleanupResult = try await prepareCleanTranscript(
            raw: rawTranscript,
            profile: profile,
            lexicon: lexicon,
            appContext: active.appContext
        )

        // Apply voice commands (punctuation, whitespace, "delete that", custom) after cleanup.
        let finalText = voiceCommandService.apply(to: cleanupResult.transcript.text)

        var insertResult = await insertionService.insert(text: finalText, target: active.appContext)
        insertResult.cleanupOutcome = cleanupResult.outcome

        let entry = TranscriptEntry(
            appBundleID: active.appContext.bundleIdentifier,
            rawText: rawTranscript.text,
            cleanText: finalText,
            audioURL: nil,
            insertionStatus: insertResult.status
        )
        try await historyStore.append(entry: entry)

        // Feed session data to the learning engine for adaptive improvement.
        if let learningEngine {
            await learningEngine.observeSession(
                rawText: rawTranscript.text,
                cleanText: finalText,
                removedFillers: cleanupResult.transcript.removedFillers,
                appBundleID: active.appContext.bundleIdentifier
            )
            await learningEngine.save()
        }

        return insertResult
    }

    public func cancel(sessionID: SessionID) async {
        activeSessions.removeValue(forKey: sessionID)
        await captureService.cancelCapture(sessionID: sessionID)
    }

    public func setHandsFreeEnabled(_ enabled: Bool) {
        isHandsFreeEnabled = enabled
    }

    private func prepareCleanTranscript(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon,
        appContext: AppContext
    ) async throws -> CleanupExecutionResult {
        if profile.commandPolicy == .passthrough,
           appContext.isIDE,
           raw.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            return CleanupExecutionResult(
                transcript: CleanTranscript(text: raw.text),
                outcome: CleanupOutcome(source: .localOnly)
            )
        }

        do {
            let cleaned = try await cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            return CleanupExecutionResult(
                transcript: cleaned,
                outcome: CleanupOutcome(source: .localSuccess)
            )
        } catch {
            var fallback = try await fallbackCleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)
            let warning = "Primary cleanup unavailable, used local fallback."
            fallback.uncertaintyFlags.append(warning)
            return CleanupExecutionResult(
                transcript: fallback,
                outcome: CleanupOutcome(source: .localFallback, warning: warning)
            )
        }
    }
}

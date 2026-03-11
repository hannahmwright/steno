import Foundation

/// Persistent data backing the adaptive learning system.
///
/// Stored as a single JSON file and updated after each dictation session.
public struct LearningData: Sendable, Codable, Equatable {
    /// How many times each lowercased word has been dictated.
    public var wordFrequencies: [String: Int]

    /// User corrections: raw word → corrected word, with occurrence count.
    public var corrections: [Correction]

    /// N-gram phrase counts for snippet auto-suggestion.
    public var phraseFrequencies: [String: Int]

    /// Per-app usage statistics for style profile auto-tuning.
    public var appStats: [String: AppUsageStats]

    public init(
        wordFrequencies: [String: Int] = [:],
        corrections: [Correction] = [],
        phraseFrequencies: [String: Int] = [:],
        appStats: [String: AppUsageStats] = [:]
    ) {
        self.wordFrequencies = wordFrequencies
        self.corrections = corrections
        self.phraseFrequencies = phraseFrequencies
        self.appStats = appStats
    }

    public static let empty = LearningData()
}

// MARK: - Correction

public struct Correction: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var rawWord: String
    public var correctedWord: String
    public var count: Int
    public var lastSeen: Date
    public var promoted: Bool

    public init(
        id: UUID = UUID(),
        rawWord: String,
        correctedWord: String,
        count: Int = 1,
        lastSeen: Date = Date(),
        promoted: Bool = false
    ) {
        self.id = id
        self.rawWord = rawWord
        self.correctedWord = correctedWord
        self.count = count
        self.lastSeen = lastSeen
        self.promoted = promoted
    }
}

// MARK: - App Usage Stats

public struct AppUsageStats: Sendable, Codable, Equatable {
    public var sessionCount: Int
    public var totalWordCount: Int
    public var fillerRate: Double
    public var averageLength: Double
    public var structureHints: StructureHints

    public init(
        sessionCount: Int = 0,
        totalWordCount: Int = 0,
        fillerRate: Double = 0,
        averageLength: Double = 0,
        structureHints: StructureHints = StructureHints()
    ) {
        self.sessionCount = sessionCount
        self.totalWordCount = totalWordCount
        self.fillerRate = fillerRate
        self.averageLength = averageLength
        self.structureHints = structureHints
    }
}

public struct StructureHints: Sendable, Codable, Equatable {
    /// Fraction of transcripts that look like short commands (< 5 words).
    public var shortCommandRate: Double
    /// Fraction of transcripts that use formal language signals.
    public var formalityScore: Double
    /// Fraction of transcripts ending with a period or structured punctuation.
    public var punctuationRate: Double

    public init(
        shortCommandRate: Double = 0,
        formalityScore: Double = 0,
        punctuationRate: Double = 0
    ) {
        self.shortCommandRate = shortCommandRate
        self.formalityScore = formalityScore
        self.punctuationRate = punctuationRate
    }
}

// MARK: - Snippet Suggestion

public struct SnippetSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { phrase }
    public var phrase: String
    public var occurrences: Int

    public init(phrase: String, occurrences: Int) {
        self.phrase = phrase
        self.occurrences = occurrences
    }
}

// MARK: - Style Suggestion

public struct StyleSuggestion: Sendable, Equatable {
    public var bundleID: String
    public var suggestedProfile: StyleProfile
    public var reason: String
    public var confidence: Double

    public init(bundleID: String, suggestedProfile: StyleProfile, reason: String, confidence: Double) {
        self.bundleID = bundleID
        self.suggestedProfile = suggestedProfile
        self.reason = reason
        self.confidence = confidence
    }
}

import Testing
import Foundation
@testable import MurmurKit

// MARK: - Word Frequency Tests

@Test("Learning engine tracks word frequencies from clean text")
func wordFrequencyTracking() async {
    let engine = LearningEngine(storageURL: tempURL())

    await engine.observeSession(
        rawText: "um hello world hello",
        cleanText: "hello world hello",
        removedFillers: ["um"],
        appBundleID: "com.test.app"
    )

    let helloCount = await engine.frequency(of: "hello")
    let worldCount = await engine.frequency(of: "world")
    #expect(helloCount == 2)
    #expect(worldCount == 1)
}

@Test("Word frequencies are case-insensitive")
func wordFrequencyCaseInsensitive() async {
    let engine = LearningEngine(storageURL: tempURL())

    await engine.observeSession(
        rawText: "Hello HELLO hello",
        cleanText: "Hello HELLO hello",
        removedFillers: [],
        appBundleID: "com.test"
    )

    let count = await engine.frequency(of: "hello")
    #expect(count == 3)
}

// MARK: - Correction Tests

@Test("Corrections are recorded and counted")
func correctionRecording() async {
    let engine = LearningEngine(storageURL: tempURL())

    let first = await engine.recordCorrection(rawWord: "react", correctedWord: "React")
    #expect(first == nil)

    let second = await engine.recordCorrection(rawWord: "react", correctedWord: "React")
    #expect(second == nil)

    let corrections = await engine.corrections()
    #expect(corrections.count == 1)
    #expect(corrections[0].count == 2)
}

@Test("Correction promotes to lexicon entry after threshold")
func correctionPromotion() async {
    let engine = LearningEngine(storageURL: tempURL())

    for i in 1..<LearningEngine.correctionPromotionThreshold {
        let result = await engine.recordCorrection(rawWord: "kubernetes", correctedWord: "Kubernetes")
        #expect(result == nil, "Should not promote at count \(i)")
    }

    let promoted = await engine.recordCorrection(rawWord: "kubernetes", correctedWord: "Kubernetes")
    #expect(promoted != nil)
    #expect(promoted?.term == "kubernetes")
    #expect(promoted?.preferred == "Kubernetes")
    #expect(promoted?.scope == .global)
}

@Test("Correction does not promote twice")
func correctionNoDoublePromotion() async {
    let engine = LearningEngine(storageURL: tempURL())

    for _ in 1...LearningEngine.correctionPromotionThreshold {
        _ = await engine.recordCorrection(rawWord: "api", correctedWord: "API")
    }

    // One more after promotion
    let extra = await engine.recordCorrection(rawWord: "api", correctedWord: "API")
    #expect(extra == nil, "Should not promote again")
}

// MARK: - Snippet Suggestion Tests

@Test("Phrase frequencies are tracked for n-grams")
func phraseFrequencyTracking() async {
    let engine = LearningEngine(storageURL: tempURL())

    // Say the same phrase multiple times across sessions
    for _ in 1...6 {
        await engine.observeSession(
            rawText: "thanks for your patience on this",
            cleanText: "thanks for your patience on this",
            removedFillers: [],
            appBundleID: "com.test"
        )
    }

    let suggestions = await engine.snippetSuggestions()
    // Should suggest multi-word phrases that appeared >= threshold times
    let hasPatience = suggestions.contains { $0.phrase.contains("thanks") && $0.phrase.contains("patience") }
    #expect(hasPatience, "Should suggest frequently repeated phrases")
}

@Test("Snippet suggestions exclude existing triggers")
func snippetSuggestionsExcludeExisting() async {
    let engine = LearningEngine(storageURL: tempURL())

    for _ in 1...6 {
        await engine.observeSession(
            rawText: "on my way home now",
            cleanText: "on my way home now",
            removedFillers: [],
            appBundleID: "com.test"
        )
    }

    let withExclusion = await engine.snippetSuggestions(excluding: ["on my way"])
    let hasOnMyWay = withExclusion.contains { $0.phrase == "on my way" }
    #expect(!hasOnMyWay, "Should not suggest already-existing snippet triggers")
}

@Test("Dismissed snippet suggestions are removed")
func snippetSuggestionDismissal() async {
    let engine = LearningEngine(storageURL: tempURL())

    for _ in 1...6 {
        await engine.observeSession(
            rawText: "let me know if you need anything",
            cleanText: "let me know if you need anything",
            removedFillers: [],
            appBundleID: "com.test"
        )
    }

    let before = await engine.snippetSuggestions()
    let hasSuggestion = before.contains { $0.phrase.contains("let me know") }

    if hasSuggestion {
        let match = before.first { $0.phrase.contains("let me know") }!
        await engine.dismissSnippetSuggestion(phrase: match.phrase)

        let after = await engine.snippetSuggestions()
        let stillHas = after.contains { $0.phrase == match.phrase }
        #expect(!stillHas, "Dismissed suggestion should not reappear")
    }
}

// MARK: - App Stats Tests

@Test("Per-app usage stats are tracked")
func appStatsTracking() async {
    let engine = LearningEngine(storageURL: tempURL())

    await engine.observeSession(
        rawText: "um send the report",
        cleanText: "send the report",
        removedFillers: ["um"],
        appBundleID: "com.apple.mail"
    )
    await engine.observeSession(
        rawText: "uh forward to team",
        cleanText: "forward to team",
        removedFillers: ["uh"],
        appBundleID: "com.apple.mail"
    )

    let stats = await engine.appStats(for: "com.apple.mail")
    #expect(stats != nil)
    #expect(stats?.sessionCount == 2)
    #expect(stats?.totalWordCount == 6)
    #expect(stats?.fillerRate ?? 0 > 0, "Should track filler rate")
}

@Test("Style suggestions require minimum sessions")
func styleSuggestionsMinSessions() async {
    let engine = LearningEngine(storageURL: tempURL())

    // Only 2 sessions — below threshold
    for _ in 1...2 {
        await engine.observeSession(
            rawText: "go", cleanText: "go", removedFillers: [], appBundleID: "com.test"
        )
    }

    let suggestions = await engine.styleSuggestions(currentProfiles: [:])
    #expect(suggestions.isEmpty, "Should not suggest with too few sessions")
}

// MARK: - Vocabulary Bonus in Ranker Tests

@Test("Ranker gives vocabulary bonus for known words")
func rankerVocabularyBonus() async {
    let freqs: [String: Int] = ["kubernetes": 50, "deploy": 30, "cluster": 20]
    let ranker = LocalCleanupRanker(wordFrequencies: freqs)

    let profile = StyleProfile(
        name: "test",
        tone: .natural,
        structureMode: .natural,
        fillerPolicy: .balanced,
        commandPolicy: .transform
    )

    let familiarCandidate = CleanupCandidate(
        text: "deploy the kubernetes cluster",
        appliedEdits: [],
        removedFillers: [],
        rulePathID: "test-familiar"
    )
    let unfamiliarCandidate = CleanupCandidate(
        text: "deploy the kubernetes cluster",
        appliedEdits: [],
        removedFillers: [],
        rulePathID: "test-unfamiliar"
    )

    let familiarScore = ranker.scoreCandidate(
        rawText: "deploy the kubernetes cluster",
        candidate: familiarCandidate,
        profile: profile
    )

    // With no frequencies, score should be lower
    let emptyRanker = LocalCleanupRanker(wordFrequencies: [:])
    let noFreqScore = emptyRanker.scoreCandidate(
        rawText: "deploy the kubernetes cluster",
        candidate: unfamiliarCandidate,
        profile: profile
    )

    #expect(familiarScore.totalScore > noFreqScore.totalScore,
            "Candidates with user's known vocabulary should score higher")
}

// MARK: - Persistence Tests

@Test("Learning data persists and loads")
func persistenceRoundTrip() async {
    let url = tempURL()
    let engine1 = LearningEngine(storageURL: url)

    await engine1.observeSession(
        rawText: "hello world",
        cleanText: "hello world",
        removedFillers: [],
        appBundleID: "com.test"
    )
    _ = await engine1.recordCorrection(rawWord: "wrld", correctedWord: "world")
    await engine1.save()

    // Load from same file
    let engine2 = LearningEngine(storageURL: url)
    let freq = await engine2.frequency(of: "hello")
    #expect(freq == 1)

    let corrections = await engine2.corrections()
    #expect(corrections.count == 1)
    #expect(corrections[0].rawWord == "wrld")

    // Cleanup
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Helpers

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("murmur-test-\(UUID().uuidString).json")
}

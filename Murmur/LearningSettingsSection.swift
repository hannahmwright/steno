import SwiftUI
import MurmurKit

struct LearningSettingsSection: View {
    @EnvironmentObject private var controller: DictationController
    @State private var snippetSuggestions: [SnippetSuggestion] = []
    @State private var styleSuggestions: [StyleSuggestion] = []
    @State private var corrections: [Correction] = []
    @State private var correctionRaw: String = ""
    @State private var correctionFixed: String = ""

    var body: some View {
        settingsCardWithSubtitle(
            "Adaptive Learning",
            subtitle: "Murmur learns from your dictation to improve over time"
        ) {
            // Quick correction entry
            correctionEntrySection

            // Snippet suggestions
            if !snippetSuggestions.isEmpty {
                Divider()
                snippetSuggestionsSection
            }

            // Style suggestions
            if !styleSuggestions.isEmpty {
                Divider()
                styleSuggestionsSection
            }

            // Correction log
            if !corrections.isEmpty {
                Divider()
                correctionLogSection
            }
        }
        .task { await refreshLearningData() }
    }

    // MARK: - Correction Entry

    private var correctionEntrySection: some View {
        VStack(alignment: .leading, spacing: MurmurDesign.xs) {
            Text("Teach a Correction")
                .font(MurmurDesign.callout())
                .foregroundStyle(MurmurDesign.textSecondary)

            HStack(spacing: MurmurDesign.sm) {
                TextField("Wrong word", text: $correctionRaw)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(MurmurDesign.textSecondary)
                TextField("Correct word", text: $correctionFixed)
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !correctionRaw.isEmpty, !correctionFixed.isEmpty else { return }
                    Task {
                        await controller.submitCorrection(
                            rawWord: correctionRaw,
                            correctedWord: correctionFixed
                        )
                        correctionRaw = ""
                        correctionFixed = ""
                        await refreshLearningData()
                    }
                } label: {
                    Label("Teach", systemImage: "graduationcap")
                }
                .buttonStyle(.bordered)
            }

            Text("After seeing the same correction \(LearningEngine.correctionPromotionThreshold) times, it auto-adds to your lexicon.")
                .font(MurmurDesign.caption())
                .foregroundStyle(MurmurDesign.textSecondary)
        }
    }

    // MARK: - Snippet Suggestions

    private var snippetSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: MurmurDesign.xs) {
            Text("Suggested Shortcuts")
                .font(MurmurDesign.callout())
                .foregroundStyle(MurmurDesign.textSecondary)

            Text("You say these phrases often. Want to make them shortcuts?")
                .font(MurmurDesign.caption())
                .foregroundStyle(MurmurDesign.textSecondary)

            ForEach(snippetSuggestions.prefix(5)) { suggestion in
                HStack(spacing: MurmurDesign.sm) {
                    Text("\"\(suggestion.phrase)\"")
                        .font(MurmurDesign.callout())
                        .lineLimit(1)
                    Spacer()
                    Text("\(suggestion.occurrences)x")
                        .font(MurmurDesign.caption())
                        .foregroundStyle(MurmurDesign.textSecondary)
                    Button("Add") {
                        Task {
                            await controller.acceptSnippetSuggestion(suggestion)
                            await refreshLearningData()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Dismiss") {
                        Task {
                            await controller.dismissSnippetSuggestion(suggestion)
                            await refreshLearningData()
                        }
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                .padding(.vertical, MurmurDesign.xxs)
            }
        }
    }

    // MARK: - Style Suggestions

    private var styleSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: MurmurDesign.xs) {
            Text("App Profile Suggestions")
                .font(MurmurDesign.callout())
                .foregroundStyle(MurmurDesign.textSecondary)

            ForEach(styleSuggestions, id: \.bundleID) { suggestion in
                HStack(spacing: MurmurDesign.sm) {
                    VStack(alignment: .leading, spacing: MurmurDesign.xxs) {
                        Text(suggestion.bundleID)
                            .font(MurmurDesign.callout())
                        Text(suggestion.reason)
                            .font(MurmurDesign.caption())
                            .foregroundStyle(MurmurDesign.textSecondary)
                    }
                    Spacer()
                    Button("Apply") {
                        Task {
                            await controller.acceptStyleSuggestion(suggestion)
                            await refreshLearningData()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, MurmurDesign.xxs)
                .padding(.horizontal, MurmurDesign.sm)
                .background(MurmurDesign.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall))
            }
        }
    }

    // MARK: - Correction Log

    private var correctionLogSection: some View {
        DisclosureGroup("Correction Log (\(corrections.count))") {
            ForEach(corrections.prefix(20)) { correction in
                HStack(spacing: MurmurDesign.sm) {
                    Text("\"\(correction.rawWord)\" \u{2192} \"\(correction.correctedWord)\"")
                        .font(MurmurDesign.callout())
                    Spacer()
                    Text("\(correction.count)x")
                        .font(MurmurDesign.caption())
                        .foregroundStyle(MurmurDesign.textSecondary)
                    if correction.promoted {
                        Text("In Lexicon")
                            .font(MurmurDesign.label())
                            .padding(.horizontal, MurmurDesign.sm)
                            .padding(.vertical, MurmurDesign.xxs)
                            .background(MurmurDesign.accent.opacity(MurmurDesign.opacitySubtle))
                            .foregroundStyle(MurmurDesign.accent)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, MurmurDesign.xxs)
            }
        }
    }

    // MARK: - Data Loading

    private func refreshLearningData() async {
        let existingTriggers = Set(controller.preferences.snippets.map(\.trigger))
        snippetSuggestions = await controller.fetchSnippetSuggestions(
            excluding: existingTriggers
        )
        styleSuggestions = await controller.fetchStyleSuggestions()
        corrections = await controller.fetchCorrections()
    }
}

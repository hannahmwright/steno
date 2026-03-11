import SwiftUI
import MurmurKit

struct SettingsView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var preferencesDraft: AppPreferences = .default

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MurmurDesign.lg) {
                PermissionsSettingsSection()
                RecordingSettingsSection(
                    preferences: $preferencesDraft,
                    hotkeyRegistrationMessage: controller.hotkeyRegistrationMessage
                )
                EngineSettingsSection(
                    preferences: $preferencesDraft,
                    controller: controller
                )
                InsertionSettingsSection(preferences: $preferencesDraft)
                MediaSettingsSection(preferences: $preferencesDraft)
                LexiconSettingsSection(preferences: $preferencesDraft)
                CleanupStyleSettingsSection(preferences: $preferencesDraft)
                SnippetsSettingsSection(preferences: $preferencesDraft)
                VoiceCommandsSettingsSection(preferences: $preferencesDraft)
                LearningSettingsSection()
                GeneralSettingsSection(
                    preferences: $preferencesDraft,
                    launchAtLoginWarning: controller.launchAtLoginWarning
                )

                // Bottom actions
                HStack(spacing: MurmurDesign.sm) {
                    Button("Save & Apply") {
                        controller.applySettingsDraft(preferences: preferencesDraft)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MurmurDesign.accent)

                    Spacer()
                }
            }
            .padding(.vertical, MurmurDesign.lg)
        }
        .onAppear {
            preferencesDraft = controller.preferences
        }
    }
}

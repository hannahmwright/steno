import SwiftUI
import MurmurKit

struct VoiceCommandsSettingsSection: View {
    @Binding var preferences: AppPreferences
    @State private var newTrigger: String = ""
    @State private var newReplacement: String = ""

    private var builtInCommands: [VoiceCommand] {
        preferences.voiceCommands.filter(\.isBuiltIn)
    }

    private var customCommands: [VoiceCommand] {
        preferences.voiceCommands.filter { !$0.isBuiltIn }
    }

    var body: some View {
        settingsCardWithSubtitle(
            "Voice Commands",
            subtitle: "Say a trigger phrase to insert punctuation, whitespace, or custom text"
        ) {
            // Built-in commands
            DisclosureGroup("Built-in Commands (\(builtInCommands.count))") {
                ForEach(builtInCommands) { command in
                    builtInRow(command)
                }
            }

            // Custom commands
            if !customCommands.isEmpty {
                Divider()
                Text("Custom Commands")
                    .font(MurmurDesign.callout())
                    .foregroundStyle(MurmurDesign.textSecondary)

                ForEach(customCommands) { command in
                    entryRow(
                        leading: "\u{201C}\(command.trigger)\u{201D} \u{2192} \(actionLabel(command.action))"
                    ) {
                        preferences.voiceCommands.removeAll { $0.id == command.id }
                    }
                }
            }

            Divider()

            HStack(spacing: MurmurDesign.sm) {
                TextField("Trigger phrase", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                TextField("Inserts text", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !newTrigger.isEmpty, !newReplacement.isEmpty else { return }
                    let command = VoiceCommand(
                        trigger: newTrigger,
                        action: .insertText(newReplacement),
                        isEnabled: true,
                        isBuiltIn: false
                    )
                    if let idx = preferences.voiceCommands.firstIndex(where: {
                        !$0.isBuiltIn && $0.trigger.lowercased() == command.trigger.lowercased()
                    }) {
                        preferences.voiceCommands[idx] = command
                    } else {
                        preferences.voiceCommands.append(command)
                    }
                    newTrigger = ""
                    newReplacement = ""
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func builtInRow(_ command: VoiceCommand) -> some View {
        HStack(spacing: MurmurDesign.sm) {
            Toggle(isOn: Binding(
                get: { command.isEnabled },
                set: { newValue in
                    if let idx = preferences.voiceCommands.firstIndex(where: { $0.id == command.id }) {
                        preferences.voiceCommands[idx].isEnabled = newValue
                    }
                }
            )) {
                HStack(spacing: MurmurDesign.xs) {
                    Text(command.trigger)
                        .font(MurmurDesign.callout())
                    Text("\u{2192} \(actionLabel(command.action))")
                        .font(MurmurDesign.caption())
                        .foregroundStyle(MurmurDesign.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, MurmurDesign.xxs)
    }

    private func actionLabel(_ action: VoiceCommand.Action) -> String {
        switch action {
        case .insertText(let text):
            let display = text
                .replacingOccurrences(of: "\n\n", with: "\\u{00B6}\\u{00B6}")
                .replacingOccurrences(of: "\n", with: "\\u{00B6}")
                .replacingOccurrences(of: "\t", with: "\\u{21E5}")
            return display.isEmpty ? "(empty)" : display
        case .deletePrevious:
            return "delete previous sentence"
        }
    }
}

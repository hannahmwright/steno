import Foundation
import MurmurKit

struct AppPreferences: Codable, Sendable, Equatable {
    struct General: Codable, Sendable, Equatable {
        var launchAtLoginEnabled: Bool
        var showDockIcon: Bool
        var showOnboarding: Bool

        init(launchAtLoginEnabled: Bool, showDockIcon: Bool, showOnboarding: Bool) {
            self.launchAtLoginEnabled = launchAtLoginEnabled
            self.showDockIcon = showDockIcon
            self.showOnboarding = showOnboarding
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            launchAtLoginEnabled = try container.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
            showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
            showOnboarding = try container.decodeIfPresent(Bool.self, forKey: .showOnboarding) ?? false
        }
    }

    struct Hotkeys: Codable, Sendable, Equatable {
        var optionPressToTalkEnabled: Bool
        var handsFreeGlobalKeyCode: UInt16?

        init(optionPressToTalkEnabled: Bool, handsFreeGlobalKeyCode: UInt16? = 79) {
            self.optionPressToTalkEnabled = optionPressToTalkEnabled
            self.handsFreeGlobalKeyCode = handsFreeGlobalKeyCode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            optionPressToTalkEnabled = try container.decodeIfPresent(Bool.self, forKey: .optionPressToTalkEnabled) ?? true
            handsFreeGlobalKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .handsFreeGlobalKeyCode) ?? 79
        }
    }

    struct Dictation: Codable, Sendable, Equatable {
        var modelDirectoryPath: String
        var modelArch: MoonshineModelPreset

        init(
            modelDirectoryPath: String,
            modelArch: MoonshineModelPreset = .smallStreaming
        ) {
            self.modelDirectoryPath = modelDirectoryPath
            self.modelArch = modelArch
        }

        enum CodingKeys: String, CodingKey {
            case modelDirectoryPath
            case modelArch
            case modelPath
            case whisperCLIPath
            case threadCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaultModelArch: MoonshineModelPreset = .smallStreaming
            let defaultPath = MoonshineModelPaths.defaultModelDirectoryPath(for: defaultModelArch)

            let decodedPath = try container.decodeIfPresent(String.self, forKey: .modelDirectoryPath)
            let legacyPath = try container.decodeIfPresent(String.self, forKey: .modelPath)
            let resolvedPath: String

            if let decodedPath, !decodedPath.isEmpty {
                resolvedPath = decodedPath
            } else if let legacyPath, !legacyPath.isEmpty {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: legacyPath, isDirectory: &isDirectory), isDirectory.boolValue {
                    resolvedPath = legacyPath
                } else {
                    resolvedPath = defaultPath
                }
            } else {
                resolvedPath = defaultPath
            }

            modelDirectoryPath = resolvedPath
            modelArch = try container.decodeIfPresent(MoonshineModelPreset.self, forKey: .modelArch) ?? defaultModelArch
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(modelDirectoryPath, forKey: .modelDirectoryPath)
            try container.encode(modelArch, forKey: .modelArch)
        }
    }

    struct Insertion: Codable, Sendable, Equatable {
        var orderedMethods: [InsertionMethod]

        init(orderedMethods: [InsertionMethod]) {
            self.orderedMethods = orderedMethods
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            orderedMethods = try container.decodeIfPresent([InsertionMethod].self, forKey: .orderedMethods) ?? [.direct, .accessibility, .clipboardPaste]
        }
    }

    struct Media: Codable, Sendable, Equatable {
        var pauseDuringHandsFree: Bool
        var pauseDuringPressToTalk: Bool

        init(pauseDuringHandsFree: Bool = true, pauseDuringPressToTalk: Bool = true) {
            self.pauseDuringHandsFree = pauseDuringHandsFree
            self.pauseDuringPressToTalk = pauseDuringPressToTalk
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pauseDuringHandsFree = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringHandsFree) ?? true
            pauseDuringPressToTalk = try container.decodeIfPresent(Bool.self, forKey: .pauseDuringPressToTalk) ?? true
        }
    }

    var general: General
    var hotkeys: Hotkeys
    var dictation: Dictation
    var insertion: Insertion
    var media: Media

    var lexiconEntries: [LexiconEntry]
    var globalStyleProfile: StyleProfile
    var appStyleProfiles: [String: StyleProfile]
    var snippets: [Snippet]
    var voiceCommands: [VoiceCommand]

    static var `default`: AppPreferences {
        return AppPreferences(
            general: .init(
                launchAtLoginEnabled: false,
                showDockIcon: true,
                showOnboarding: true
            ),
            hotkeys: .init(
                optionPressToTalkEnabled: true,
                handsFreeGlobalKeyCode: 79
            ),
            dictation: .init(
                modelDirectoryPath: MoonshineModelPaths.defaultModelDirectoryPath(for: .smallStreaming),
                modelArch: .smallStreaming
            ),
            insertion: .init(orderedMethods: [.direct, .accessibility, .clipboardPaste]),
            media: .init(pauseDuringHandsFree: true, pauseDuringPressToTalk: true),
            lexiconEntries: [
                LexiconEntry(term: "murmurh", preferred: "Murmur", scope: .global),
                LexiconEntry(term: "murmur kit", preferred: "MurmurKit", scope: .global)
            ],
            globalStyleProfile: .init(
                name: "Default",
                tone: .natural,
                structureMode: .paragraph,
                fillerPolicy: .balanced,
                commandPolicy: .transform
            ),
            appStyleProfiles: [:],
            snippets: [],
            voiceCommands: VoiceCommand.builtIns
        )
    }

    mutating func normalize() {
        let supported: Set<InsertionMethod> = [.direct, .accessibility, .clipboardPaste]
        var seen: Set<InsertionMethod> = []
        var normalized: [InsertionMethod] = []

        for method in insertion.orderedMethods where supported.contains(method) && !seen.contains(method) {
            normalized.append(method)
            seen.insert(method)
        }

        if !seen.contains(.clipboardPaste) {
            normalized.append(.clipboardPaste)
        }

        insertion.orderedMethods = normalized
        if dictation.modelDirectoryPath.isEmpty {
            dictation.modelDirectoryPath = MoonshineModelPaths.defaultModelDirectoryPath(for: dictation.modelArch)
        }
    }
}

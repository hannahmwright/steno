import Foundation

/// Detects voice command trigger phrases in transcript text and executes their actions.
///
/// Commands are matched case-insensitively as whole phrases. When a trigger is found,
/// it is replaced by the command's action output (inserted text, punctuation, etc.).
/// The ``deletePrevious`` action removes the sentence before the trigger.
///
/// Commands are processed left-to-right in a single pass. Longer triggers are matched
/// first so that "exclamation point" is not partially consumed by a hypothetical shorter
/// trigger.
public final class VoiceCommandService: @unchecked Sendable {
    private var commands: [VoiceCommand] = []
    private var sortedEnabled: [VoiceCommand] = []

    public init(commands: [VoiceCommand] = []) {
        update(commands: commands)
    }

    public func update(commands newCommands: [VoiceCommand]) {
        commands = newCommands
        // Sort longest trigger first so greedy matching prefers longer phrases.
        sortedEnabled = newCommands
            .filter(\.isEnabled)
            .sorted { $0.trigger.count > $1.trigger.count }
    }

    /// Processes the given text, replacing voice command triggers with their output.
    public func apply(to text: String) -> String {
        guard !sortedEnabled.isEmpty else { return text }

        var result = text

        for command in sortedEnabled {
            result = applyCommand(command, to: result)
        }

        return cleanUpWhitespace(result)
    }

    private func applyCommand(_ command: VoiceCommand, to text: String) -> String {
        let trigger = command.trigger
        guard !trigger.isEmpty else { return text }

        // Build a regex that matches the trigger as a whole phrase, case-insensitive.
        // Use word boundaries to avoid matching inside other words.
        let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(escapedTrigger)\\b",
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else { return text }

        switch command.action {
        case .insertText(let replacement):
            return replaceMatches(matches, in: text, with: replacement)

        case .deletePrevious:
            return deletePreviousSentences(at: matches, in: text)
        }
    }

    private func replaceMatches(_ matches: [NSTextCheckingResult], in text: String, with replacement: String) -> String {
        var result = text as NSString
        // Replace in reverse order so ranges stay valid.
        for match in matches.reversed() {
            let range = match.range

            // If the replacement is punctuation (single non-alphanumeric char),
            // remove any trailing space before the trigger so "hello period" → "hello." not "hello .".
            var adjustedRange = range
            if replacement.count == 1, !replacement.first!.isLetter, !replacement.first!.isNumber {
                if adjustedRange.location > 0 {
                    let charBefore = result.substring(with: NSRange(location: adjustedRange.location - 1, length: 1))
                    if charBefore == " " {
                        adjustedRange = NSRange(location: adjustedRange.location - 1, length: adjustedRange.length + 1)
                    }
                }
            }

            result = result.replacingCharacters(in: adjustedRange, with: replacement) as NSString
        }
        return result as String
    }

    private func deletePreviousSentences(at matches: [NSTextCheckingResult], in text: String) -> String {
        var result = text as NSString

        // Process in reverse to keep ranges valid.
        for match in matches.reversed() {
            let triggerStart = match.range.location
            let triggerEnd = match.range.location + match.range.length

            // Find the sentence boundary before the trigger.
            let textBeforeTrigger = result.substring(to: triggerStart)
                .trimmingCharacters(in: .whitespaces)

            // Find the last sentence-ending punctuation before this trigger.
            let sentenceEnders: CharacterSet = CharacterSet(charactersIn: ".!?\n")
            var sentenceStart = 0
            if let lastEnderRange = textBeforeTrigger.rangeOfCharacter(from: sentenceEnders, options: .backwards) {
                sentenceStart = textBeforeTrigger.distance(
                    from: textBeforeTrigger.startIndex,
                    to: lastEnderRange.upperBound
                )
            }

            // Delete from sentenceStart to the end of the trigger.
            let deleteRange = NSRange(location: sentenceStart, length: triggerEnd - sentenceStart)
            result = result.replacingCharacters(in: deleteRange, with: "") as NSString
        }

        return result as String
    }

    private func cleanUpWhitespace(_ text: String) -> String {
        // Collapse multiple spaces into one, trim edges.
        var result = text
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        // Clean up space before punctuation.
        for punct in [".", ",", "!", "?", ":", ";"] {
            result = result.replacingOccurrences(of: " \(punct)", with: punct)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

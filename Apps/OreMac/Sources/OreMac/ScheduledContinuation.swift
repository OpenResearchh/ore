import Foundation
import OreProtocol

/// A turn the user asked ORE to send once a usage/session limit lifts.
struct ScheduledContinuation: Codable, Equatable, Sendable, Identifiable {
    var workspaceID: WorkspaceID
    var chatID: ChatID
    var resumeAt: Date
    var prompt: String

    var id: ChatID { chatID }

    static let defaultPrompt = "Continue from where you left off."
}

/// Wall-clock reset times as they appear in provider copy
/// ("resets 5:30am (Asia/Calcutta)") plus the unix timestamps on `RateLimitReport`.
enum UsageLimitReset {
    static func parse(_ message: String, now: Date = Date()) -> Date? {
        let value = message
        guard let time = firstTime(in: value) else { return nil }
        let timeZone = firstTimeZone(in: value) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        let identifier = timeZone.identifier
        return "\(time) (\(identifier))"
    }

    static func relativeLabel(until date: Date, now: Date = Date()) -> String {
        if date <= now { return "now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func firstTime(in message: String) -> (hour: Int, minute: Int)? {
        let pattern = #"(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let hourRange = Range(match.range(at: 1), in: message),
              let minuteRange = Range(match.range(at: 2), in: message),
              var hour = Int(message[hourRange]),
              let minute = Int(message[minuteRange])
        else { return nil }

        if match.range(at: 3).location != NSNotFound,
           let meridianRange = Range(match.range(at: 3), in: message) {
            let meridian = message[meridianRange].lowercased().replacingOccurrences(of: ".", with: "")
            if meridian.hasPrefix("p"), hour < 12 { hour += 12 }
            if meridian.hasPrefix("a"), hour == 12 { hour = 0 }
        }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func firstTimeZone(in message: String) -> TimeZone? {
        guard let regex = try? NSRegularExpression(pattern: #"\(([A-Za-z_+\-/]+)\)"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message)
        else { return nil }
        let raw = String(message[range])
        if let zone = TimeZone(identifier: raw) { return zone }
        if raw == "Asia/Calcutta" { return TimeZone(identifier: "Asia/Kolkata") }
        return TimeZone(identifier: raw.replacingOccurrences(of: " ", with: "_"))
    }
}

extension Attachment {
    var isImage: Bool {
        if let mimeType, mimeType.hasPrefix("image/") { return true }
        return hasExtension(in: Self.imageExtensions)
    }

    var isText: Bool {
        if let mimeType, mimeType.hasPrefix("text/") { return true }
        return hasExtension(in: Self.textExtensions)
    }

    /// Images, and text files we copied into `.context/attachments/` (pasted
    /// screenshots and long pastes), can pop a hover preview. Workspace file
    /// mentions stay tokens — previewing a whole source file on hover would be
    /// noise.
    var isHoverPreviewable: Bool {
        if isImage { return true }
        return isText && relativePath.hasPrefix(".context/attachments/")
    }

    func fileURL(worktreePath: String) -> URL {
        URL(fileURLWithPath: worktreePath).appendingPathComponent(relativePath)
    }

    /// A short sentence stays in the composer; a dump of logs, a function, or a
    /// long paragraph becomes `@pasted-text.txt` so the bubble doesn't become a
    /// wall of pasted prose.
    static func shouldAttachPastedText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count >= minimumPastedCharacters { return true }
        let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.count >= minimumPastedLines
    }

    static let minimumPastedLines = 12
    static let minimumPastedCharacters = 1_500

    private func hasExtension(in set: Set<String>) -> Bool {
        Self.hasExtension(in: set, path: relativePath, name: displayName)
    }

    private static func hasExtension(in set: Set<String>, path: String, name: String) -> Bool {
        set.contains((path as NSString).pathExtension.lowercased())
            || set.contains((name as NSString).pathExtension.lowercased())
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp",
    ]

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "log", "xml", "yml", "yaml",
        "html", "css", "toml", "ini", "env", "sh",
    ]
}

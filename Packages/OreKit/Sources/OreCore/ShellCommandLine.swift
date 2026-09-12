import Foundation

/// A shell command line, split just far enough to judge what it does.
///
/// This is not a shell. It understands exactly the constructs a judgement
/// needs — quoting, the operators that chain commands, redirection — and marks
/// anything that hides code from it (`$(…)`, backticks, process substitution,
/// subshells, heredocs) as *opaque*. Opaque lines are never auto-approved: the
/// classifier can only vouch for what it can read.
///
/// The asymmetry is deliberate. Misreading a harmless command as risky costs
/// the user one click; misreading a risky one as harmless is the failure this
/// must never have. Every ambiguity resolves towards asking.
public struct ShellCommandLine: Sendable, Equatable {
    /// One simple command: the part between `|`, `&&`, `||`, `;` or a newline.
    public struct Segment: Sendable, Equatable {
        /// Leading `NAME=value` assignments, raw.
        public var assignments: [String] = []
        /// The command and its arguments, with quoting removed.
        public var words: [String] = []
        /// Files written through `>`, `>>` or `&>`. `/dev/null` and fd
        /// duplication (`2>&1`) never appear here.
        public var writes: [String] = []
        /// Files read through `<`.
        public var reads: [String] = []
        /// Whether stdin comes from the previous segment's `|`.
        public var readsFromPipe = false

        public var command: String? { words.first }
        public var arguments: ArraySlice<String> { words.dropFirst() }
    }

    public var segments: [Segment]
    /// Why the line cannot be read in full, if it can't.
    public var opaqueReason: String?
    /// A lone `&` sends work to the background, beyond the turn that asked.
    public var runsInBackground: Bool

    public var isOpaque: Bool { opaqueReason != nil }

    public static func parse(_ text: String) -> ShellCommandLine {
        var parser = Parser(characters: Array(text))
        return parser.run()
    }

    /// `NAME=value`, the form a shell treats as an assignment rather than a
    /// command.
    static func isAssignment(_ word: String) -> Bool { Parser.isAssignment(word) }
}

private struct Parser {
    enum Pending { case write, read }

    let characters: [Character]
    var index = 0
    var segments: [ShellCommandLine.Segment] = []
    var current = ShellCommandLine.Segment()
    var word = ""
    /// A quoted empty string (`""`) is still a word.
    var wordStarted = false
    var pending: Pending?
    var opaque: String?
    var background = false

    init(characters: [Character]) { self.characters = characters }

    func peek(_ offset: Int = 1) -> Character? {
        let at = index + offset
        return at < characters.count ? characters[at] : nil
    }

    mutating func markOpaque(_ reason: String) {
        if opaque == nil { opaque = reason }
    }

    mutating func run() -> ShellCommandLine {
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "'":
                wordStarted = true
                index += 1
                while index < characters.count, characters[index] != "'" {
                    word.append(characters[index])
                    index += 1
                }
                if index >= characters.count { markOpaque("an unterminated quote") }
            case "\"":
                readDoubleQuoted()
            case "\\":
                if let next = peek() {
                    word.append(next)
                    wordStarted = true
                    index += 1
                }
            case "`":
                markOpaque("a nested command")
            case "$" where peek() == "(":
                markOpaque("a nested command")
                word.append(character)
            case "<" where peek() == "(", ">" where peek() == "(":
                markOpaque("process substitution")
            case "(", ")":
                markOpaque("a subshell")
            case "#" where word.isEmpty && !wordStarted:
                // A comment runs to the end of the line and does nothing.
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            case " ", "\t":
                endWord()
            case "\n", ";":
                endSegment(piped: false)
            case "&":
                if peek() == "&" {
                    endSegment(piped: false)
                    index += 1
                } else if peek() == ">" {
                    endWord()
                    index += 1
                    if peek() == ">" { index += 1 }
                    pending = .write
                } else {
                    background = true
                    endSegment(piped: false)
                }
            case "|":
                if peek() == "|" {
                    endSegment(piped: false)
                    index += 1
                } else {
                    endSegment(piped: true)
                }
            case ">":
                readRedirect()
                continue
            case "<":
                if peek() == "<" {
                    // A heredoc's body is text the classifier would have to
                    // parse as data *and* can't see the command reading it.
                    markOpaque("a heredoc")
                    index += 1
                } else {
                    dropFileDescriptorPrefix()
                    pending = .read
                }
            default:
                word.append(character)
            }
            index += 1
        }
        endSegment(piped: false)
        return ShellCommandLine(
            segments: segments,
            opaqueReason: opaque,
            runsInBackground: background
        )
    }

    /// Double quotes remove quoting but still expand `$(…)` and backticks.
    mutating func readDoubleQuoted() {
        wordStarted = true
        index += 1
        while index < characters.count, characters[index] != "\"" {
            let character = characters[index]
            if character == "\\", let next = peek(), "\"\\$`".contains(next) {
                word.append(next)
                index += 2
                continue
            }
            if character == "`" || (character == "$" && peek() == "(") {
                markOpaque("a nested command")
            }
            word.append(character)
            index += 1
        }
        if index >= characters.count { markOpaque("an unterminated quote") }
    }

    /// `>`, `>>`, `2>`, `>&2`, `2>&1`, `>/dev/null`.
    mutating func readRedirect() {
        dropFileDescriptorPrefix()
        index += 1
        if peek(0) == ">" { index += 1 }
        if peek(0) == "&" {
            // Duplicating a descriptor writes no file.
            index += 1
            while let next = peek(0), next.isNumber || next == "-" { index += 1 }
            return
        }
        pending = .write
    }

    /// The `2` in `2>` belongs to the redirect, not the command's arguments.
    mutating func dropFileDescriptorPrefix() {
        if !word.isEmpty, !wordStarted || word.allSatisfy(\.isNumber), word.allSatisfy(\.isNumber) {
            word = ""
            wordStarted = false
        } else {
            endWord()
        }
    }

    mutating func endWord() {
        guard wordStarted || !word.isEmpty else { return }
        defer { word = ""; wordStarted = false }
        switch pending {
        case .write:
            pending = nil
            if word != "/dev/null" { current.writes.append(word) }
        case .read:
            pending = nil
            current.reads.append(word)
        case nil:
            if current.words.isEmpty, Self.isAssignment(word) {
                current.assignments.append(word)
            } else {
                current.words.append(word)
            }
        }
    }

    mutating func endSegment(piped: Bool) {
        endWord()
        if pending != nil {
            markOpaque("an incomplete redirect")
            pending = nil
        }
        let segment = current
        if !segment.words.isEmpty || !segment.assignments.isEmpty
            || !segment.writes.isEmpty || !segment.reads.isEmpty {
            segments.append(segment)
        }
        current = ShellCommandLine.Segment()
        current.readsFromPipe = piped
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

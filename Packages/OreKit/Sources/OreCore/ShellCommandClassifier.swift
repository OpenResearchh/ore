import Foundation

/// What running a shell command would do, judged before it runs.
public struct ShellCommandVerdict: Sendable, Equatable {
    /// Ordered from harmless to "ask the user". A command line is as risky as
    /// its riskiest part, so combining verdicts keeps the worst.
    public enum Kind: Int, Sendable, Comparable, CaseIterable {
        /// Only looks: listing, reading, searching, diffs, `git status`.
        case inspect
        /// The project's own build, test and lint tooling.
        case build
        /// Local, reversible changes inside the project — `mkdir`, `git add`,
        /// a commit. Undoable with git, and nothing leaves the machine.
        case edit
        /// Not recognised. Neither vouched for nor flagged.
        case unknown
        /// Needs the user whatever the setting: deletes files, touches
        /// credentials, changes remote or published state, needs privilege,
        /// installs software, or hides code ORE cannot read.
        case attention

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    /// Why, completing "This command …" — "deletes files", "pushes to a remote".
    public var reason: String

    public init(_ kind: Kind, _ reason: String) {
        self.kind = kind
        self.reason = reason
    }

    static func inspect(_ reason: String) -> Self { .init(.inspect, reason) }
    static func build(_ reason: String) -> Self { .init(.build, reason) }
    static func edit(_ reason: String) -> Self { .init(.edit, reason) }
    static func unknown(_ reason: String) -> Self { .init(.unknown, reason) }
    static func attention(_ reason: String) -> Self { .init(.attention, reason) }

    /// The riskier of two verdicts. On a tie the first reason stands.
    func worst(_ other: Self) -> Self { other.kind > kind ? other : self }
}

/// Reads a shell command and says what it would do.
///
/// Built so the user can stop approving `ls` forty times an afternoon without
/// ORE ever waving through something that deserves a look. It recognises a
/// deliberately bounded vocabulary — the inspection, build and git commands
/// agents actually run — and everything outside it is `unknown`, never
/// `inspect`. Anything it cannot read in full (nested commands, heredocs,
/// subshells) is `attention`. It errs, always, towards asking.
public enum ShellCommandClassifier {
    /// How deep `sh -c '…'` is followed before giving up and asking.
    static let maximumNesting = 2

    public static func classify(_ command: String) -> ShellCommandVerdict {
        classify(command, depth: 0)
    }

    static func classify(_ command: String, depth: Int) -> ShellCommandVerdict {
        let line = ShellCommandLine.parse(command)
        if let hidden = line.opaqueReason {
            return .attention("contains \(hidden), which ORE can't read")
        }
        if line.runsInBackground { return .attention("keeps running in the background") }
        guard !line.segments.isEmpty else { return .unknown("is empty") }

        var verdict = ShellCommandVerdict.inspect("only reads")
        for segment in line.segments {
            verdict = verdict.worst(classify(segment, depth: depth))
            if verdict.kind == .attention { break }
        }
        return verdict
    }

    static func classify(_ segment: ShellCommandLine.Segment, depth: Int) -> ShellCommandVerdict {
        // Credentials first, anywhere on the line: `cat ~/.ssh/id_rsa` is a
        // read, and exactly the read that must never happen unasked.
        let everyWord = segment.assignments + segment.words + segment.reads + segment.writes
        if everyWord.contains(where: Secrets.touches) {
            return .attention("touches credentials or secrets")
        }
        for assignment in segment.assignments {
            if let reason = Environment.risk(ofAssigning: assignment) { return .attention(reason) }
        }

        var verdict = ShellCommandVerdict.inspect("only reads")
        for target in segment.writes {
            guard ProjectPaths.isInside(target) else {
                return .attention("writes a file outside the project")
            }
            verdict = verdict.worst(.edit("writes a file"))
        }

        let words = unwrapped(segment.words)
        guard let first = words.first else {
            return segment.assignments.isEmpty ? verdict : verdict.worst(.inspect("sets a variable"))
        }
        if first.contains("$") { return .attention("runs a command named by a variable") }
        let name = (first as NSString).lastPathComponent
        let command = rule(
            for: name,
            invokedAs: first,
            arguments: Array(words.dropFirst()),
            segment: segment,
            depth: depth
        )
        return verdict.worst(command)
    }

    /// Classifies `words` as though they were the whole segment — for
    /// wrappers such as `env A=1 cmd` or `bundle exec cmd`.
    static func reclassify(
        _ words: [String], in segment: ShellCommandLine.Segment, depth: Int
    ) -> ShellCommandVerdict {
        var inner = segment
        inner.assignments = Array(words.prefix { ShellCommandLine.isAssignment($0) })
        inner.words = Array(words.dropFirst(inner.assignments.count))
        return classify(inner, depth: depth)
    }

    /// `time`, `nice` and `timeout 60` change how long or how politely
    /// something runs, not what it does.
    static func unwrapped(_ words: [String]) -> [String] {
        var rest = words[...]
        while let head = rest.first {
            switch head {
            case "time", "nice":
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") {
                    rest = rest.dropFirst()
                    if flag == "-n", let level = rest.first, Int(level) != nil { rest = rest.dropFirst() }
                }
            case "timeout", "gtimeout":
                rest = rest.dropFirst()
                while let flag = rest.first, flag.hasPrefix("-") { rest = rest.dropFirst() }
                if let limit = rest.first, limit.first?.isNumber == true { rest = rest.dropFirst() }
            default:
                return Array(rest)
            }
        }
        return Array(rest)
    }
}

// MARK: - Where a path points

enum ProjectPaths {
    /// Relative and with no way up and out — no leading `/` or `~`, no `..`,
    /// nothing expanded at run time. The scratch directory is allowed too:
    /// writing there reaches nothing the user owns.
    static func isInside(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("$"), !path.hasPrefix("~") else { return false }
        if path.split(separator: "/").contains("..") { return false }
        if path.hasPrefix("/") {
            return path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
        }
        return true
    }

    /// The arguments that are operands rather than flags.
    static func operands(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.hasPrefix("-") }
    }
}

// MARK: - Credentials and secrets

enum Secrets {
    static let directories: Set<String> = [
        ".ssh", ".aws", ".gnupg", ".azure", ".kube", ".docker", ".password-store", "gcloud",
    ]
    static let files: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", ".my.cnf",
        "credentials", "credentials.json", "service-account.json",
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "login.keychain-db",
    ]
    static let extensions: Set<String> = [
        "pem", "p12", "pfx", "key", "keystore", "jks", "ppk", "gpg", "kdbx", "mobileprovision",
    ]
    /// Committed templates, not the secrets themselves.
    static let harmlessEnvironmentFiles: Set<String> = [
        ".env.example", ".env.sample", ".env.template", ".env.dist", ".env.defaults",
    ]

    static func touches(_ word: String) -> Bool {
        if referencesSensitiveVariable(word) { return true }
        let parts = word.lowercased().split(separator: "/").map(String.init)
        guard let base = parts.last else { return false }
        if parts.contains(where: directories.contains) { return true }
        // `~/.config/gh/hosts.yml` holds the GitHub token.
        if parts.contains(".config"), parts.contains("gh") { return true }
        if files.contains(base) { return true }
        if base == ".env" || (base.hasPrefix(".env.") && !harmlessEnvironmentFiles.contains(base)) {
            return true
        }
        if let dot = base.lastIndex(of: "."), dot != base.startIndex,
           extensions.contains(String(base[base.index(after: dot)...])) {
            return true
        }
        return false
    }

    static let sensitiveParts: Set<String> = [
        "TOKEN", "SECRET", "PASSWORD", "PASSWD", "KEY", "CREDENTIAL", "CREDENTIALS",
        "AUTH", "COOKIE", "SESSION", "PRIVATE",
    ]

    /// `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, `OPENAI_API_KEY`. Matched on
    /// whole underscore-separated parts, so `MONKEY` and `KEYBOARD` are not.
    static func isSensitive(variable name: String) -> Bool {
        name.uppercased().split(separator: "_").contains { sensitiveParts.contains(String($0)) }
    }

    /// `echo $GITHUB_TOKEN` prints the token into the transcript.
    static func referencesSensitiveVariable(_ word: String) -> Bool {
        var index = word.startIndex
        while let dollar = word[index...].firstIndex(of: "$") {
            var cursor = word.index(after: dollar)
            if cursor < word.endIndex, word[cursor] == "{" { cursor = word.index(after: cursor) }
            let start = cursor
            while cursor < word.endIndex,
                  word[cursor].isLetter || word[cursor].isNumber || word[cursor] == "_" {
                cursor = word.index(after: cursor)
            }
            if cursor > start, isSensitive(variable: String(word[start..<cursor])) { return true }
            index = cursor
        }
        return false
    }
}

// MARK: - Environment assignments

enum Environment {
    /// Variables that change *what* runs rather than how it is configured:
    /// search paths, injected libraries, hooks and helpers other programs
    /// execute.
    static let dangerous: Set<String> = [
        "PATH", "BASH_ENV", "ENV", "PROMPT_COMMAND", "IFS", "HOME", "SHELL",
        "NODE_OPTIONS", "PYTHONPATH", "PYTHONSTARTUP", "RUBYOPT", "PERL5OPT", "PERL5LIB",
        "GIT_SSH", "GIT_SSH_COMMAND", "GIT_EXEC_PATH", "GIT_ASKPASS", "SSH_ASKPASS",
        "EDITOR", "VISUAL", "GIT_EDITOR", "PAGER", "GIT_PAGER",
    ]
    /// `PAGER=cat git log` is how agents stop git blocking on a pager.
    static let harmlessPagers: Set<String> = ["", "cat", "less", "more"]

    static func risk(ofAssigning assignment: String) -> String? {
        let name = String(assignment.prefix { $0 != "=" })
        let value = String(assignment.dropFirst(name.count + 1))
        if Secrets.isSensitive(variable: name) { return "sets a credential" }
        let upper = name.uppercased()
        if (upper == "PAGER" || upper == "GIT_PAGER"), harmlessPagers.contains(value) { return nil }
        if dangerous.contains(upper) || upper.hasPrefix("DYLD_") || upper.hasPrefix("LD_")
            || upper.hasPrefix("GIT_CONFIG") {
            return "changes how commands run"
        }
        return nil
    }
}

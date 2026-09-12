import Foundation

/// Developer-tool rules for `ShellCommandClassifier`. Read-only queries and
/// familiar local verification are routine; publishing, installation, remote
/// state, and destructive/history-changing operations always need attention.
extension ShellCommandClassifier {
    static func git(_ arguments: [String]) -> ShellCommandVerdict {
        guard let action = arguments.first else { return .inspect("shows git help") }
        switch action {
        case "status", "diff", "log", "show", "rev-parse", "ls-files", "grep",
             "describe", "blame", "shortlog":
            return .inspect("reads repository state")
        case "branch", "tag", "remote", "worktree":
            let mutating = ["-d", "-D", "-m", "-M", "--delete", "--move", "add", "remove", "prune"]
            return arguments.contains(where: mutating.contains)
                ? .attention("changes repository structure")
                : .inspect("lists repository state")
        case "add", "restore": return .edit("updates the local working state")
        case "commit": return .edit("creates a local commit")
        case "fetch": return .build("updates remote-tracking information")
        case "push": return .attention("pushes to a remote")
        case "pull", "merge", "rebase", "reset", "clean", "checkout", "switch", "cherry-pick",
             "revert", "stash", "am", "apply":
            return .attention("changes git history or the working tree")
        case "clone", "init": return .attention("creates a repository")
        default: return .unknown("uses an unrecognised git operation")
        }
    }

    static func gitHub(_ arguments: [String]) -> ShellCommandVerdict {
        guard let group = arguments.first else { return .inspect("shows GitHub CLI help") }
        let action = arguments.dropFirst().first ?? ""
        switch group {
        case "auth": return action == "status" ? .inspect("checks GitHub sign-in") : .attention("changes GitHub authentication")
        case "repo": return ["list", "view"].contains(action) ? .inspect("reads GitHub repositories") : .attention("changes a GitHub repository")
        case "search": return .inspect("searches GitHub")
        case "issue": return ["list", "view", "status"].contains(action) ? .inspect("reads GitHub issues") : .attention("changes a GitHub issue")
        case "pr": return ["list", "view", "status", "checks", "diff"].contains(action) ? .inspect("reads pull requests") : .attention("changes a pull request")
        case "run", "workflow": return ["list", "view"].contains(action) ? .inspect("reads workflow state") : .attention("changes workflow state")
        case "api":
            let mutationFlags = ["-X", "--method", "-f", "--raw-field", "-F", "--field", "--input"]
            let mutates = arguments.contains { argument in
                mutationFlags.contains(argument)
                    || mutationFlags.contains(where: { argument.hasPrefix($0 + "=") })
            }
            return mutates ? .attention("may change GitHub state") : .inspect("reads from GitHub")
        default: return .unknown("uses an unrecognised GitHub operation")
        }
    }

    static func javaScript(_ name: String, _ arguments: [String]) -> ShellCommandVerdict {
        guard let action = arguments.first else { return .inspect("shows package-manager help") }
        if ["install", "add", "remove", "uninstall", "update", "upgrade", "publish", "link"].contains(action) {
            return .attention("changes installed packages or publishes one")
        }
        if ["list", "ls", "outdated", "why", "info", "view"].contains(action) {
            return .inspect("reads package information")
        }
        if ["test", "build", "lint", "check", "typecheck"].contains(action) {
            return .build("runs project verification")
        }
        if action == "run", let script = arguments.dropFirst().first,
           ["test", "build", "lint", "check", "typecheck"].contains(script) {
            return .build("runs project verification")
        }
        return .unknown("runs a project package script")
    }

    static func python(_ name: String, _ arguments: [String]) -> ShellCommandVerdict {
        let action = arguments.first ?? ""
        if ["install", "uninstall", "add", "remove", "publish", "upload", "sync"].contains(action) {
            return .attention("changes installed packages or publishes one")
        }
        if ["list", "show", "check", "tree"].contains(action) { return .inspect("reads package information") }
        return .unknown("runs Python tooling")
    }

    static func cargo(_ arguments: [String]) -> ShellCommandVerdict {
        let action = arguments.first ?? ""
        if ["build", "check", "test", "clippy", "doc"].contains(action) { return .build("runs Rust project verification") }
        if ["metadata", "tree", "version", "locate-project"].contains(action) { return .inspect("reads Rust project information") }
        if ["install", "uninstall", "publish", "yank", "add", "remove", "update"].contains(action) { return .attention("changes packages or publishes one") }
        return .unknown("runs Cargo")
    }

    static func goTool(_ arguments: [String]) -> ShellCommandVerdict {
        let action = arguments.first ?? ""
        if ["build", "test", "vet"].contains(action) { return .build("runs Go project verification") }
        if ["list", "version", "env"].contains(action) { return .inspect("reads Go project information") }
        if ["install", "get", "clean"].contains(action) { return .attention("changes packages or build state") }
        return .unknown("runs Go tooling")
    }

    static func swift(_ arguments: [String]) -> ShellCommandVerdict {
        let action = arguments.first ?? ""
        if ["build", "test"].contains(action) { return .build("runs Swift project verification") }
        if action == "package", ["describe", "show-dependencies", "dump-package"].contains(arguments.dropFirst().first ?? "") {
            return .inspect("reads Swift package information")
        }
        if ["--version", "-version"].contains(action) { return .inspect("prints the Swift version") }
        return .unknown("runs Swift tooling")
    }

    static func xcodebuild(_ arguments: [String]) -> ShellCommandVerdict {
        let inspectFlags = ["-list", "-showBuildSettings", "-showsdks", "-version"]
        return arguments.contains(where: inspectFlags.contains)
            ? .inspect("reads Xcode project information")
            : .build("builds or tests the Xcode project")
    }

    static func task(_ arguments: [String]) -> ShellCommandVerdict {
        if arguments.contains(where: { ["install", "deploy", "publish", "release", "clean"].contains($0.lowercased()) }) {
            return .attention("runs a potentially consequential project task")
        }
        return .build("runs a project build task")
    }

    static func brew(_ arguments: [String]) -> ShellCommandVerdict {
        let action = arguments.first ?? ""
        return ["list", "info", "outdated", "doctor", "config", "--version"].contains(action)
            ? .inspect("reads Homebrew state")
            : .attention("changes installed software")
    }

    static func container(_ name: String, _ arguments: [String]) -> ShellCommandVerdict {
        let action = arguments.first ?? ""
        if ["ps", "images", "inspect", "logs", "stats", "version", "info"].contains(action) {
            return .inspect("reads container state")
        }
        if action == "build" { return .build("builds a local container image") }
        return .attention("changes container state")
    }

    static func bundler(
        _ arguments: [String], segment: ShellCommandLine.Segment, depth: Int
    ) -> ShellCommandVerdict {
        guard arguments.first == "exec" else {
            return ["list", "check", "show"].contains(arguments.first ?? "")
                ? .inspect("reads Ruby bundle state")
                : .attention("changes installed Ruby packages")
        }
        return reclassify(Array(arguments.dropFirst()), in: segment, depth: depth)
    }

    static func checkTool(_ name: String, _ arguments: [String]) -> ShellCommandVerdict? {
        let verification: Set<String> = [
            "eslint", "stylelint", "tsc", "biome", "ruff", "mypy", "pyright", "pytest",
            "rspec", "rubocop", "golangci-lint", "swiftlint", "swiftformat", "shellcheck",
        ]
        guard verification.contains(name) else { return nil }
        if ["biome", "ruff", "swiftformat"].contains(name),
           arguments.contains(where: { $0 == "--write" || $0 == "--fix" }) {
            return .edit("formats project files")
        }
        return .build("runs project verification")
    }
}

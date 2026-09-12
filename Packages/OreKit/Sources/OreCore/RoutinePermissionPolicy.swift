import Foundation
import OreProtocol

/// The small, auditable set of terminal work that is routine enough not to
/// interrupt the user. This is intentionally a positive list: commands with
/// shell indirection, output redirection, privilege changes, installs, remote
/// mutations, or unfamiliar verbs continue through the normal permission UI.
public enum RoutinePermissionPolicy {
    public static func shouldAllow(
        _ request: PermissionRequest,
        workspacePath: String
    ) -> Bool {
        automaticApproval(for: request, workspacePath: workspacePath) != nil
    }

    /// The approval ORE would give on the user's behalf, and what it would
    /// record about it, or `nil` to ask them.
    ///
    /// One function rather than a `Bool` beside a separate description: a
    /// request that runs unasked never becomes a card, so this record is the
    /// only trace that it happened and the only account of why ORE judged it
    /// safe. The two must not be able to disagree.
    public static func automaticApproval(
        for request: PermissionRequest,
        workspacePath: String
    ) -> AutomaticApproval? {
        func approval(_ command: String, _ reason: String) -> AutomaticApproval {
            AutomaticApproval(
                toolCallID: request.toolCallID, command: command, reason: reason
            )
        }

        switch request.toolName {
        case "BashOutput":
            return approval("BashOutput", "reads the output of a command already running")
        case "Read":
            guard let path = request.input["file_path"]?.stringValue
                ?? request.input["path"]?.stringValue,
                isInsideWorkspace(path, workspacePath: workspacePath)
            else { return nil }
            return approval("Read \(path)", "reads a file inside the workspace")
        case "Glob", "Grep":
            // With no explicit path these tools search their session cwd,
            // which is the worktree. An explicit path must stay there too.
            let path = request.input["path"]?.stringValue
            guard path.map({ isInsideWorkspace($0, workspacePath: workspacePath) }) ?? true
            else { return nil }
            return approval(
                "\(request.toolName) \(path ?? ".")", "searches inside the workspace"
            )
        case "Bash":
            let cwd = request.input["cwd"]?.stringValue
            guard isInsideWorkspace(cwd, workspacePath: workspacePath),
                  let command = ShellCommandClassifier.command(in: request),
                  let automatic = ShellApprovalPolicy.automaticApproval(
                      for: request, level: .routine
                  ),
                  referencedPathsStayInsideWorkspace(
                      command, cwd: cwd, workspacePath: workspacePath
                  )
            else { return nil }
            return automatic
        default:
            return nil
        }
    }

    public static func isRoutine(
        _ command: String,
        cwd: String? = nil,
        workspacePath: String
    ) -> Bool {
        guard isInsideWorkspace(cwd, workspacePath: workspacePath) else { return false }
        return ShellCommandClassifier.classify(command).kind <= .build
            && referencedPathsStayInsideWorkspace(
                command, cwd: cwd, workspacePath: workspacePath
            )
    }

    private static func isInsideWorkspace(_ path: String?, workspacePath: String) -> Bool {
        guard let path, !path.isEmpty else { return true }
        let root = canonical(URL(fileURLWithPath: workspacePath))
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = root.appendingPathComponent(path)
        }
        return contains(canonical(candidate), root: root)
    }

    /// The classifier decides what each command does; this second boundary
    /// decides where its explicit filesystem operands point. It catches quiet
    /// reads such as `cat /etc/passwd`, `cd ../other && rg TODO`, and a symlink
    /// in the worktree that resolves outside it.
    private static func referencedPathsStayInsideWorkspace(
        _ command: String,
        cwd: String?,
        workspacePath: String
    ) -> Bool {
        let root = canonical(URL(fileURLWithPath: workspacePath))
        var directory = cwd.flatMap { raw -> URL? in
            guard !raw.isEmpty else { return nil }
            return raw.hasPrefix("/")
                ? canonical(URL(fileURLWithPath: raw))
                : canonical(root.appendingPathComponent(raw))
        } ?? root

        for segment in ShellCommandLine.parse(command).segments {
            let values = segment.assignments + segment.words + segment.reads
            if values.contains(where: { $0.contains("$") || $0.hasPrefix("~") }) {
                return false
            }
            for raw in segment.reads + Array(segment.words.dropFirst()) {
                guard looksLikePath(raw, relativeTo: directory) else { continue }
                let candidate = raw.hasPrefix("/")
                    ? URL(fileURLWithPath: raw)
                    : directory.appendingPathComponent(raw)
                guard contains(canonical(candidate), root: root) else { return false }
            }
            if segment.words.first.map({ ($0 as NSString).lastPathComponent }) == "cd",
               let destination = segment.words.dropFirst().first {
                directory = destination.hasPrefix("/")
                    ? canonical(URL(fileURLWithPath: destination))
                    : canonical(directory.appendingPathComponent(destination))
                guard contains(directory, root: root) else { return false }
            }
        }
        return true
    }

    private static func looksLikePath(_ value: String, relativeTo directory: URL) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        if URL(string: value)?.scheme != nil { return false }
        if value.hasPrefix("/") || value.hasPrefix(".") || value.hasPrefix("~")
            || value.contains("/") { return true }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(value).path
        )
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}

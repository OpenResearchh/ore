import Foundation

struct AgentFileReferenceResolver {
    struct Resolved: Equatable {
        var path: String
        var line: Int?
    }

    /// Agent output may use a repository-relative path, an absolute worktree
    /// path, a `file://` URL, or a short basename. Resolve through the workspace
    /// index first, then the worktree itself — `.context` is hidden from the
    /// tree on purpose, but a "Read all" link still has to open the note.
    static func resolve(
        _ reference: String,
        worktreePath: String,
        files: [WorkspaceFileNode]
    ) -> Resolved? {
        var candidate = reference.removingPercentEncoding ?? reference
        if candidate.hasPrefix("file://"), let url = URL(string: candidate) {
            candidate = url.path
        }

        var focusLine: Int?
        if let match = candidate.range(of: #":\d+(?:[:,]\d+)?$"#, options: .regularExpression) {
            let locator = candidate[match].dropFirst()
            focusLine = Int(locator.prefix { $0.isNumber })
            candidate.removeSubrange(match)
        }

        let root = worktreePath.hasSuffix("/") ? worktreePath : worktreePath + "/"
        if candidate.hasPrefix(root) { candidate.removeFirst(root.count) }
        while candidate.hasPrefix("./") { candidate.removeFirst(2) }
        candidate = unwrapPunctuation(candidate)

        guard !candidate.isEmpty, !candidate.split(separator: "/").contains("..") else {
            return nil
        }

        let index = flatten(files)
        if let path = index.first(where: { $0.path == candidate })?.path
            ?? index.first(where: { $0.path.hasSuffix("/" + candidate) })?.path
            ?? index.first(where: { $0.name == candidate })?.path {
            return Resolved(path: path, line: focusLine)
        }

        return resolveOnDisk(candidate, worktreePath: worktreePath, line: focusLine)
    }

    /// Strips wrapping quotes and a trailing sentence period without eating the
    /// leading dot on `.context/…` or `.env`.
    static func unwrapPunctuation(_ path: String) -> String {
        var candidate = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = CharacterSet(charactersIn: "`'\"([<{")
        let trailing = CharacterSet(charactersIn: "`'\".,;:!?)]}>")
        while let first = candidate.unicodeScalars.first, leading.contains(first) {
            candidate.removeFirst()
        }
        while let last = candidate.unicodeScalars.last, trailing.contains(last) {
            candidate.removeLast()
        }
        return candidate
    }

    private static func resolveOnDisk(
        _ candidate: String,
        worktreePath: String,
        line: Int?
    ) -> Resolved? {
        guard !candidate.hasPrefix("/"), !worktreePath.isEmpty else { return nil }
        let root = URL(fileURLWithPath: worktreePath).standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(candidate).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path == root.path || url.path.hasPrefix(prefix) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return Resolved(path: candidate, line: line)
    }

    static func flatten(_ nodes: [WorkspaceFileNode]) -> [WorkspaceFileNode] {
        nodes.flatMap { node in
            node.isDirectory ? flatten(node.children ?? []) : [node]
        }
    }
}

import Foundation

struct AgentFileReferenceResolver {
    struct Resolved: Equatable {
        var path: String
        var line: Int?
    }

    /// Agent output may use a repository-relative path, an absolute worktree
    /// path, a `file://` URL, or a short basename. Resolve all of those through
    /// the workspace index so clicks open only files ORE knows are inside this
    /// workspace.
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
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "`'\"()[]{}<>.,"))

        let index = flatten(files)
        let resolved = index.first(where: { $0.path == candidate })?.path
            ?? index.first(where: { $0.path.hasSuffix("/" + candidate) })?.path
            ?? index.first(where: { $0.name == candidate })?.path
        guard let path = resolved, !path.split(separator: "/").contains("..") else { return nil }
        return Resolved(path: path, line: focusLine)
    }

    static func flatten(_ nodes: [WorkspaceFileNode]) -> [WorkspaceFileNode] {
        nodes.flatMap { node in
            node.isDirectory ? flatten(node.children ?? []) : [node]
        }
    }
}

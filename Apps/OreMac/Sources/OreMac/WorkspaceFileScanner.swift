import Foundation

/// Walks a worktree for the All files list, Quick Open, and @-mentions.
///
/// The old walk was depth-first and dropped later siblings once it hit a
/// 6,000-node ceiling. `.context` sorts first (dot-folders beat `src/`), so a
/// busy attachments dump made the inspector look empty except for `.context`.
struct WorkspaceFileScanner: Sendable {
    var fileLimit: Int
    var hideNames: Set<String>
    var skipRecursionNames: Set<String>

    static let `default` = WorkspaceFileScanner(
        fileLimit: 6_000,
        hideNames: [".git", ".DS_Store", ".context"],
        skipRecursionNames: [
            "node_modules", ".build", "DerivedData", "Pods", ".swiftpm",
            ".next", ".nuxt", ".output", ".gradle", ".cache", ".turbo",
            ".venv", "venv", "dist", "target", "build", "__pycache__", "coverage",
        ]
    )

    func scan(at root: String) -> [WorkspaceFileNode] {
        var visited = 0
        return children(
            of: URL(fileURLWithPath: root),
            relativeBase: "",
            visited: &visited
        )
    }

    private func children(
        of directory: URL,
        relativeBase: String,
        visited: inout Int
    ) -> [WorkspaceFileNode] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }

        let sorted = urls.sorted { first, second in
            let firstDirectory = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let secondDirectory = (try? second.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if firstDirectory != secondDirectory { return firstDirectory }
            return first.lastPathComponent.localizedStandardCompare(second.lastPathComponent)
                == .orderedAscending
        }

        // Every immediate child is kept. The file limit only stops *recursion*,
        // so a large folder that sorts first cannot erase `src/` at the root.
        return sorted.compactMap { url in
            let name = url.lastPathComponent
            if hideNames.contains(name) { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isDirectory == true
            let relative = relativeBase.isEmpty ? name : relativeBase + "/" + name
            let canRecurse = isDirectory
                && values?.isSymbolicLink != true
                && !skipRecursionNames.contains(name)
                && visited < fileLimit
            let nested: [WorkspaceFileNode]?
            if canRecurse {
                nested = children(of: url, relativeBase: relative, visited: &visited)
            } else if isDirectory {
                nested = []
            } else {
                nested = nil
            }
            visited += 1
            return WorkspaceFileNode(
                path: relative,
                name: name,
                isDirectory: isDirectory,
                children: nested
            )
        }
    }
}

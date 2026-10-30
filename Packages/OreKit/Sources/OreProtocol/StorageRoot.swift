import Foundation

/// Where a storage root lives relative to the machine.
public enum StorageRootKind: String, Sendable, Codable, Hashable {
    /// `~/ore` or `$ORE_HOME`. Always registered, never removable.
    case `internal`
    /// A user-picked folder, typically on a removable volume.
    case external
}

/// Volume identity the OS is willing to give us. Network disks and some disk
/// images have no UUID; remount then falls back to the stored path.
public struct VolumeIdentity: Sendable, Hashable, Codable {
    public var uuid: String?
    public var name: String?

    public init(uuid: String? = nil, name: String? = nil) {
        self.uuid = uuid
        self.name = name
    }
}

public struct MountedVolume: Sendable, Hashable {
    public var url: URL
    public var identity: VolumeIdentity

    public init(url: URL, identity: VolumeIdentity) {
        self.url = url
        self.identity = identity
    }
}

/// Filesystem questions the registry asks without taking a Foundation UI
/// dependency. Tests swap in a fake; production uses `VolumeProbe.live`.
public struct VolumeProbe: Sendable {
    public var isReachable: @Sendable (URL) -> Bool
    public var identity: @Sendable (URL) -> VolumeIdentity
    /// The volume mount point that contains `url`, when the OS reports one.
    public var volumeRoot: @Sendable (URL) -> URL?
    public var mountedVolumes: @Sendable () -> [MountedVolume]

    public init(
        isReachable: @escaping @Sendable (URL) -> Bool,
        identity: @escaping @Sendable (URL) -> VolumeIdentity,
        volumeRoot: @escaping @Sendable (URL) -> URL?,
        mountedVolumes: @escaping @Sendable () -> [MountedVolume]
    ) {
        self.isReachable = isReachable
        self.identity = identity
        self.volumeRoot = volumeRoot
        self.mountedVolumes = mountedVolumes
    }

    public static let live = VolumeProbe(
        isReachable: { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
        },
        identity: { url in
            #if os(macOS)
            let values = try? url.resourceValues(forKeys: [
                .volumeUUIDStringKey, .volumeNameKey,
            ])
            return VolumeIdentity(uuid: values?.volumeUUIDString, name: values?.volumeName)
            #else
            return VolumeIdentity(uuid: nil, name: url.lastPathComponent)
            #endif
        },
        volumeRoot: { url in
            #if os(macOS)
            (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
            #else
            nil
            #endif
        },
        mountedVolumes: {
            #if os(macOS)
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey],
                options: [.skipHiddenVolumes]
            ) ?? []
            return urls.map { url in
                let values = try? url.resourceValues(forKeys: [
                    .volumeUUIDStringKey, .volumeNameKey,
                ])
                return MountedVolume(
                    url: url,
                    identity: VolumeIdentity(
                        uuid: values?.volumeUUIDString,
                        name: values?.volumeName
                    )
                )
            }
            #else
            []
            #endif
        }
    )
}

/// A place ORE can put repositories and worktrees.
///
/// Identity is `id` plus `volumeUUID` — not the current mount path, which
/// changes when Disk Utility remounts a drive under a new name.
public struct StorageRoot: Sendable, Codable, Hashable, Identifiable {
    public var id: StorageRootID
    public var kind: StorageRootKind
    public var displayName: String
    /// Last-known absolute path of this OreHome-shaped directory.
    public var mountPath: String
    public var volumeUUID: String?
    /// Path of this root under the volume mount point. Empty when the
    /// registered folder *is* the volume. Used to rebuild `mountPath` after
    /// remount.
    public var pathRelativeToVolume: String
    public var isAvailable: Bool
    public var isPreferred: Bool
    public var createdAt: Date
    public var lastSeenAt: Date?

    public init(
        id: StorageRootID,
        kind: StorageRootKind,
        displayName: String,
        mountPath: String,
        volumeUUID: String? = nil,
        pathRelativeToVolume: String = "",
        isAvailable: Bool = true,
        isPreferred: Bool = false,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.mountPath = mountPath
        self.volumeUUID = volumeUUID
        self.pathRelativeToVolume = pathRelativeToVolume
        self.isAvailable = isAvailable
        self.isPreferred = isPreferred
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
    }

    public var mountURL: URL { URL(fileURLWithPath: mountPath, isDirectory: true) }

    public var repositoriesURL: URL {
        mountURL.appendingPathComponent("repositories", isDirectory: true)
    }

    public var workspacesURL: URL {
        mountURL.appendingPathComponent("workspaces", isDirectory: true)
    }

    public var repositoriesPath: String { repositoriesURL.path }
    public var workspacesPath: String { workspacesURL.path }

    public static func makeInternal(
        mountPath: String,
        isAvailable: Bool = true,
        isPreferred: Bool = true,
        createdAt: Date = Date()
    ) -> StorageRoot {
        StorageRoot(
            id: .internalDefault,
            kind: .internal,
            displayName: "This Mac",
            mountPath: mountPath,
            isAvailable: isAvailable,
            isPreferred: isPreferred,
            createdAt: createdAt,
            lastSeenAt: Date()
        )
    }

    /// Volume name plus folder, unless they are the same word.
    public static func suggestedDisplayName(folder: URL, identity: VolumeIdentity) -> String {
        let folderName = folder.lastPathComponent
        if let volume = identity.name, !volume.isEmpty, volume != folderName {
            return "\(volume) · \(folderName)"
        }
        return folderName
    }
}

/// Live storage facts the sidebar and composer need, attached to a workspace
/// summary rather than stored as a second query.
public struct WorkspaceStorageState: Sendable, Codable, Hashable {
    public var rootID: StorageRootID
    public var kind: StorageRootKind
    public var displayName: String
    public var isOffline: Bool

    public init(
        rootID: StorageRootID,
        kind: StorageRootKind,
        displayName: String,
        isOffline: Bool
    ) {
        self.rootID = rootID
        self.kind = kind
        self.displayName = displayName
        self.isOffline = isOffline
    }

    /// Composer and command-failure copy. Names the volume and says ORE will
    /// not silently move the worktree onto This Mac.
    public var offlineMessage: String {
        "This workspace is on “\(displayName)”, which isn’t connected. "
            + "Plug it back in to continue. ORE will not move it onto This Mac."
    }
}

/// Register a folder as an external storage root.
public struct RegisterStorageRootRequest: Sendable, Codable {
    public var path: String
    public var displayName: String?
    public var preferForNewWork: Bool

    public init(path: String, displayName: String? = nil, preferForNewWork: Bool = false) {
        self.path = path
        self.displayName = displayName
        self.preferForNewWork = preferForNewWork
    }
}

/// Pure availability, remount, and fallback rules. IO is injected as `VolumeProbe`.
public enum StorageRootResolver {
    /// Recomputes `isAvailable` and, for external roots, a remounted `mountPath`.
    ///
    /// Internal is always reported available: if the process can open the
    /// database, This Mac is there. External roots that vanish stay in the
    /// list, marked offline, so existing workspaces can still render.
    public static func refresh(
        _ roots: [StorageRoot],
        probe: VolumeProbe,
        internalMountPath: String,
        now: Date = Date()
    ) -> [StorageRoot] {
        roots.map { root in
            var root = root
            if root.kind == .internal {
                root.mountPath = internalMountPath
                root.displayName = "This Mac"
                root.isAvailable = true
                root.lastSeenAt = now
                return root
            }

            let current = URL(fileURLWithPath: root.mountPath, isDirectory: true)
            if probe.isReachable(current), uuidMatches(root.volumeUUID, probe.identity(current).uuid) {
                root.isAvailable = true
                root.lastSeenAt = now
                return root
            }

            if let uuid = root.volumeUUID,
               let mounted = probe.mountedVolumes().first(where: { $0.identity.uuid == uuid }) {
                let rebuilt = remountedURL(
                    volumeRoot: mounted.url, relative: root.pathRelativeToVolume
                )
                if probe.isReachable(rebuilt), uuidMatches(uuid, probe.identity(rebuilt).uuid) {
                    root.mountPath = rebuilt.path
                    root.isAvailable = true
                    root.lastSeenAt = now
                    return root
                }
            }

            root.isAvailable = false
            return root
        }
    }

    /// Where new workspaces and projects go. Never migrates existing ones.
    ///
    /// Requested and preferred roots that are offline are skipped, not
    /// errors — the user can still create work, on This Mac, until the
    /// volume returns.
    public static func rootForNewCreation(
        requested: StorageRootID?,
        roots: [StorageRoot]
    ) -> StorageRoot? {
        if let requested,
           let root = roots.first(where: { $0.id == requested }),
           root.isAvailable {
            return root
        }
        if let preferred = roots.first(where: { $0.isPreferred && $0.isAvailable }) {
            return preferred
        }
        return roots.first(where: { $0.kind == .internal })
            ?? roots.first(where: \.isAvailable)
    }

    public static func storageState(
        rootID: StorageRootID?,
        roots: [StorageRoot]
    ) -> WorkspaceStorageState {
        let id = rootID ?? .internalDefault
        if let root = roots.first(where: { $0.id == id }) {
            return WorkspaceStorageState(
                rootID: root.id,
                kind: root.kind,
                displayName: root.displayName,
                isOffline: !root.isAvailable
            )
        }
        // A root id we no longer have a row for: treat as offline external
        // rather than inventing This Mac, which would look like a migration.
        return WorkspaceStorageState(
            rootID: id,
            kind: id == .internalDefault ? .internal : .external,
            displayName: id == .internalDefault ? "This Mac" : "External storage",
            isOffline: id != .internalDefault
        )
    }

    public static func pathRelativeToVolume(folder: URL, volumeRoot: URL?) -> String {
        guard let volumeRoot else { return "" }
        let folderPath = folder.standardizedFileURL.path
        let volumePath = volumeRoot.standardizedFileURL.path
        if folderPath == volumePath { return "" }
        let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"
        guard folderPath.hasPrefix(prefix) else { return "" }
        return String(folderPath.dropFirst(prefix.count))
    }

    public static func remountedURL(volumeRoot: URL, relative: String) -> URL {
        if relative.isEmpty { return volumeRoot.standardizedFileURL }
        return volumeRoot.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
    }

    /// Prefix rewrite used when a volume remounts under a new path. Not a
    /// migration: the files did not move; only the mount point did.
    public static func relocating(_ path: String, from oldRoot: String, to newRoot: String) -> String {
        if path == oldRoot { return newRoot }
        let prefix = oldRoot.hasSuffix("/") ? oldRoot : oldRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        let suffix = String(path.dropFirst(prefix.count))
        let base = newRoot.hasSuffix("/") ? String(newRoot.dropLast()) : newRoot
        return base + "/" + suffix
    }

    private static func uuidMatches(_ expected: String?, _ found: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let found else { return false }
        return expected == found
    }
}

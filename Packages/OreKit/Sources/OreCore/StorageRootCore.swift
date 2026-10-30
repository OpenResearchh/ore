import Foundation
import OrePersistence
import OreProtocol
import OreSupport

extension InProcessCoreClient {
    // MARK: - Storage roots

    func refreshCachedRoots() async -> [StorageRoot] {
        let internalPath = OreHome.directory.path
        do {
            try await store.ensureInternalStorageRoot(mountPath: internalPath)
            let stored = try await store.storageRoots()
            let previous = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.mountPath) })
            let refreshed = StorageRootResolver.refresh(
                stored.map { $0.asStorageRoot() },
                probe: volumeProbe,
                internalMountPath: internalPath
            )
            for root in refreshed {
                if let old = previous[root.id.rawValue],
                   old != root.mountPath,
                   root.isAvailable,
                   root.kind == .external {
                    try? await store.relocateStorageRoot(root.id, from: old, to: root.mountPath)
                    resetGitClients()
                    // The files did not move; the mount point did. Running
                    // engines still hold the old path, so they must restart
                    // against the rewritten rows (rescan starts them).
                    let records = (try? await store.workspaces(
                        includeArchived: true, includeAssistant: true
                    )) ?? []
                    for record in records where record.storageRootID == root.id.rawValue {
                        if isEngineRunning(record.workspaceID) {
                            await stopEngine(record.workspaceID)
                        }
                    }
                }
                try? await store.saveStorageRoot(StorageRootRecord(root))
            }
            cachedRoots = refreshed
        } catch {
            cachedRoots = [StorageRoot.makeInternal(mountPath: internalPath)]
        }
        return cachedRoots
    }

    func decorate(_ summary: WorkspaceSummary, storageRootID: String? = nil) -> WorkspaceSummary {
        var summary = summary
        let id = storageRootID.map(StorageRootID.init(rawValue:))
            ?? summary.storage?.rootID
        summary.storage = StorageRootResolver.storageState(rootID: id, roots: cachedRoots)
        return summary
    }

    func decorate(_ record: WorkspaceRecord) -> WorkspaceSummary {
        decorate(record.summary(), storageRootID: record.storageRootID)
    }

    func workspacesURL(for root: StorageRoot) -> URL {
        if root.kind == .internal, let worktreeRoot {
            return worktreeRoot
        }
        return root.workspacesURL
    }

    func repositoriesURL(for root: StorageRoot) -> URL {
        root.repositoriesURL
    }

    func resolveCreationRoot(requested: StorageRootID?) async -> StorageRoot {
        let roots = cachedRoots.isEmpty ? await refreshCachedRoots() : cachedRoots
        return StorageRootResolver.rootForNewCreation(requested: requested, roots: roots)
            ?? StorageRoot.makeInternal(mountPath: OreHome.directory.path)
    }

    func storageState(for record: WorkspaceRecord) -> WorkspaceStorageState {
        let id = record.storageRootID.map(StorageRootID.init(rawValue:))
        return StorageRootResolver.storageState(rootID: id, roots: cachedRoots)
    }

    func requireStorage(for record: WorkspaceRecord) throws {
        let state = storageState(for: record)
        if state.isOffline {
            throw OreCoreError.storageOffline(volumeName: state.displayName)
        }
    }

    func registerStorageRoot(_ request: RegisterStorageRootRequest) async throws {
        let folder = FilePath.expandingTildeURL(request.path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw OreCoreError.storageRootNotFound(StorageRootID(rawValue: folder.path))
        }

        let internalPath = OreHome.directory.standardizedFileURL.path
        if folder.path == internalPath {
            try await store.setPreferredStorageRoot(.internalDefault)
            _ = await refreshCachedRoots()
            try await resync(nil)
            return
        }

        let identity = volumeProbe.identity(folder)
        let volumeRoot = volumeProbe.volumeRoot(folder)
        let relative = StorageRootResolver.pathRelativeToVolume(
            folder: folder, volumeRoot: volumeRoot
        )
        let display = request.displayName
            ?? StorageRoot.suggestedDisplayName(folder: folder, identity: identity)
        let root = StorageRoot(
            id: .generate(),
            kind: .external,
            displayName: display,
            mountPath: folder.path,
            volumeUUID: identity.uuid,
            pathRelativeToVolume: relative,
            isAvailable: true,
            isPreferred: request.preferForNewWork,
            lastSeenAt: Date()
        )
        try await store.saveStorageRoot(StorageRootRecord(root))
        if request.preferForNewWork {
            try await store.setPreferredStorageRoot(root.id)
        }
        _ = await refreshCachedRoots()
        try await resync(nil)
    }

    func removeStorageRoot(_ id: StorageRootID) async throws {
        try await store.deleteStorageRoot(id)
        resetGitClients()
        _ = await refreshCachedRoots()
        try await resync(nil)
    }

    func setPreferredStorageRoot(_ id: StorageRootID) async throws {
        try await store.setPreferredStorageRoot(id)
        _ = await refreshCachedRoots()
        try await resync(nil)
    }

    func rescanStorageRoots() async throws {
        let roots = await refreshCachedRoots()
        let records = try await store.workspaces(
            includeArchived: true, includeAssistant: true
        )
        var online: [WorkspaceRecord] = []
        for record in records {
            let state = StorageRootResolver.storageState(
                rootID: record.storageRootID.map(StorageRootID.init(rawValue:)),
                roots: roots
            )
            if state.isOffline {
                if isEngineRunning(record.workspaceID) {
                    await stopEngine(record.workspaceID)
                }
            } else if !record.isArchived {
                online.append(record)
            }
        }
        let missing = online.filter { !isEngineRunning($0.workspaceID) }
        if !missing.isEmpty {
            await startEngines(missing)
        }
        try await resync(nil)
    }

    func inferStorageRootID(containing path: String) -> StorageRootID {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let roots = cachedRoots.filter(\.isAvailable)
            .sorted { $0.mountPath.count > $1.mountPath.count }
        for root in roots {
            let prefix = root.mountPath.hasSuffix("/") ? root.mountPath : root.mountPath + "/"
            if standardized == root.mountPath || standardized.hasPrefix(prefix) {
                return root.id
            }
        }
        return .internalDefault
    }
}

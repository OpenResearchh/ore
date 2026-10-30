import Foundation
import Testing

@testable import OreCore
@testable import OreGit
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol
@testable import OreSupport

struct StorageRootResolverTests {
    private let internalRoot = StorageRoot.makeInternal(mountPath: "/Users/x/ore")

    private func external(
        path: String,
        uuid: String? = "VOL-1",
        relative: String = "ore",
        available: Bool = true,
        preferred: Bool = false
    ) -> StorageRoot {
        StorageRoot(
            id: StorageRootID(rawValue: "ext-1"),
            kind: .external,
            displayName: "T7",
            mountPath: path,
            volumeUUID: uuid,
            pathRelativeToVolume: relative,
            isAvailable: available,
            isPreferred: preferred
        )
    }

    private func probe(
        reachable: Set<String>,
        uuid: [String: String] = [:],
        mounted: [MountedVolume] = []
    ) -> VolumeProbe {
        VolumeProbe(
            isReachable: { reachable.contains($0.standardizedFileURL.path) },
            identity: { url in
                VolumeIdentity(uuid: uuid[url.standardizedFileURL.path], name: url.lastPathComponent)
            },
            volumeRoot: { url in url.deletingLastPathComponent() },
            mountedVolumes: { mounted }
        )
    }

    @Test func aMissingExternalPathIsOfflineAndKeepsItsMountPath() {
        let disk = probe(reachable: ["/Users/x/ore"])
        let roots = StorageRootResolver.refresh(
            [internalRoot, external(path: "/Volumes/T7/ore")],
            probe: disk,
            internalMountPath: "/Users/x/ore"
        )
        let ext = roots.first { $0.kind == .external }
        #expect(ext?.isAvailable == false)
        #expect(ext?.mountPath == "/Volumes/T7/ore")
        #expect(roots.first { $0.kind == .internal }?.isAvailable == true)
    }

    @Test func aMatchingVolumeUUIDRebuildsTheMountPathOnRemount() {
        let rebuilt = "/Volumes/T7 1/ore"
        let disk = probe(
            reachable: ["/Users/x/ore", rebuilt],
            uuid: [rebuilt: "VOL-1"],
            mounted: [
                MountedVolume(
                    url: URL(fileURLWithPath: "/Volumes/T7 1", isDirectory: true),
                    identity: VolumeIdentity(uuid: "VOL-1", name: "T7")
                ),
            ]
        )
        let roots = StorageRootResolver.refresh(
            [internalRoot, external(path: "/Volumes/T7/ore")],
            probe: disk,
            internalMountPath: "/Users/x/ore"
        )
        let ext = roots.first { $0.kind == .external }
        #expect(ext?.isAvailable == true)
        #expect(ext?.mountPath == rebuilt)
    }

    @Test func newWorkFallsBackToInternalWhenThePreferredRootIsOffline() {
        let roots = [
            internalRoot,
            external(path: "/Volumes/T7/ore", available: false, preferred: true),
        ]
        let chosen = StorageRootResolver.rootForNewCreation(requested: nil, roots: roots)
        #expect(chosen?.id == .internalDefault)
    }

    @Test func anExplicitOfflineRequestStillFallsBackRatherThanFailing() {
        let ext = external(path: "/Volumes/T7/ore", available: false, preferred: true)
        let chosen = StorageRootResolver.rootForNewCreation(
            requested: ext.id, roots: [internalRoot, ext]
        )
        #expect(chosen?.id == .internalDefault)
    }

    @Test func anAvailableRequestedRootWinsOverPreferred() {
        let ext = external(path: "/Volumes/T7/ore", preferred: false)
        var preferredInternal = internalRoot
        preferredInternal.isPreferred = true
        let chosen = StorageRootResolver.rootForNewCreation(
            requested: ext.id, roots: [preferredInternal, ext]
        )
        #expect(chosen?.id == ext.id)
    }

    @Test func aMissingRootIdIsOfflineExternalNotSilentlyInternal() {
        let state = StorageRootResolver.storageState(
            rootID: StorageRootID(rawValue: "gone"),
            roots: [internalRoot]
        )
        #expect(state.isOffline)
        #expect(state.kind == .external)
    }

    @Test func relocatingRewritesOnlyTheMatchingPrefix() {
        #expect(
            StorageRootResolver.relocating(
                "/Volumes/T7/ore/workspaces/repo/w",
                from: "/Volumes/T7/ore",
                to: "/Volumes/T7 1/ore"
            ) == "/Volumes/T7 1/ore/workspaces/repo/w"
        )
        #expect(
            StorageRootResolver.relocating(
                "/Volumes/T7-backup/ore/workspaces/repo/w",
                from: "/Volumes/T7/ore",
                to: "/Volumes/T7 1/ore"
            ) == "/Volumes/T7-backup/ore/workspaces/repo/w"
        )
    }
}

struct StorageRootPersistenceTests {
    @Test func aFreshStoreHasThisMacAsThePreferredRoot() async throws {
        let store = try OreStore()
        let roots = try await store.storageRoots()
        #expect(roots.contains { $0.id == StorageRootID.internalDefault.rawValue })
        #expect(roots.first { $0.kind == "internal" }?.isPreferred == true)
    }

    @Test func anExternalRootSurvivesReopen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-\(UUID().uuidString)")
            .appendingPathComponent("ore.sqlite")
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let first = try OreStore(path: path)
        try await first.saveStorageRoot(StorageRootRecord(
            id: StorageRootID(rawValue: "ssd"),
            kind: .external,
            displayName: "T7",
            mountPath: "/Volumes/T7/ore",
            volumeUUID: "VOL-1",
            pathRelativeToVolume: "ore"
        ))

        let second = try OreStore(path: path)
        let roots = try await second.storageRoots()
        #expect(roots.contains { $0.id == "ssd" && $0.volumeUUID == "VOL-1" })
    }

    @Test func remountRewritesWorktreePathsWithoutChangingTheRootId() async throws {
        let store = try OreStore()
        let ext = StorageRootID(rawValue: "ssd")
        try await store.saveStorageRoot(StorageRootRecord(
            id: ext, kind: .external, displayName: "T7",
            mountPath: "/Volumes/T7/ore"
        ))
        try await store.addRepository(RepositoryRecord(
            path: "/Volumes/T7/ore/repositories/repo",
            name: "repo",
            defaultBranch: "main",
            storageRootID: ext
        ))
        try await store.saveWorkspace(WorkspaceRecord(
            id: WorkspaceID(rawValue: "ws1"),
            name: "belgrade",
            repositoryPath: "/Volumes/T7/ore/repositories/repo",
            worktreePath: "/Volumes/T7/ore/workspaces/repo/belgrade",
            branch: "ore/belgrade",
            baseBranch: "main",
            harness: .claudeCode,
            storageRootID: ext
        ))

        try await store.relocateStorageRoot(
            ext, from: "/Volumes/T7/ore", to: "/Volumes/T7 1/ore"
        )

        let workspace = try #require(try await store.workspace(WorkspaceID(rawValue: "ws1")))
        #expect(workspace.storageRootID == ext.rawValue)
        #expect(workspace.worktreePath == "/Volumes/T7 1/ore/workspaces/repo/belgrade")
        #expect(workspace.repositoryPath == "/Volumes/T7 1/ore/repositories/repo")
    }

    @Test func removingARootThatStillHasWorkspacesIsRefused() async throws {
        let store = try OreStore()
        let ext = StorageRootID(rawValue: "ssd")
        try await store.saveStorageRoot(StorageRootRecord(
            id: ext, kind: .external, displayName: "T7",
            mountPath: "/Volumes/T7/ore"
        ))
        try await store.addRepository(RepositoryRecord(
            path: "/repo", name: "repo", defaultBranch: "main"
        ))
        try await store.saveWorkspace(WorkspaceRecord(
            id: WorkspaceID(rawValue: "ws1"),
            name: "belgrade",
            repositoryPath: "/repo",
            worktreePath: "/Volumes/T7/ore/workspaces/repo/belgrade",
            branch: "ore/belgrade",
            baseBranch: "main",
            harness: .claudeCode,
            storageRootID: ext
        ))

        await #expect(throws: StorageRootStoreError.self) {
            try await store.deleteStorageRoot(ext)
        }
    }
}

struct StorageRootCoreTests {
    private final class FakeDisk: @unchecked Sendable {
        var reachable: Set<String>
        var uuid: [String: String] = [:]
        var mounted: [MountedVolume] = []

        init(reachable: Set<String>) {
            self.reachable = reachable
        }

        var probe: VolumeProbe {
            VolumeProbe(
                isReachable: { [self] url in
                    let path = url.standardizedFileURL.path
                    return reachable.contains(path) || reachable.contains(url.path)
                },
                identity: { [self] url in
                    let path = url.standardizedFileURL.path
                    return VolumeIdentity(
                        uuid: uuid[path] ?? uuid[url.path],
                        name: url.lastPathComponent
                    )
                },
                volumeRoot: { url in url },
                mountedVolumes: { [self] in mounted }
            )
        }
    }

    @Test func creatingOnAnExternalRootPutsTheWorktreeThere() async throws {
        let fixture = try await GitFixture.initialized()
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)

        let client = InProcessCoreClient(
            store: try OreStore(),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(client)
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.registerStorageRoot(RegisterStorageRootRequest(path: volume.path)))

        guard case .snapshot(let snapshot)? = await recorder.waitFor(matching: {
            if case .snapshot(let snap) = $0 { return snap.storageRoots.contains(where: { $0.kind == .external }) }
            return false
        }) else {
            Issue.record("registered volume should appear in a snapshot")
            return
        }
        let ext = try #require(snapshot.storageRoots.first { $0.kind == .external })

        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path,
            name: "curie",
            storageRootID: ext.id
        )))
        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            Issue.record("workspace should be created on the external root")
            return
        }
        #expect(summary.worktreePath.hasPrefix(volume.path))
        #expect(summary.storage?.rootID == ext.id)
        #expect(summary.isStorageOffline == false)
        #expect(FileManager.default.fileExists(atPath: summary.worktreePath))
    }

    @Test func unplugMarksTheWorkspaceOfflineWithoutRewritingItsPath() async throws {
        let fixture = try await GitFixture.initialized()
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let disk = FakeDisk(reachable: [
            OreHome.directory.standardizedFileURL.path, volume.path,
        ])

        let store = try OreStore()
        let client = InProcessCoreClient(
            store: store,
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot,
            volumeProbe: disk.probe
        )
        let recorder = CoreEventRecorder(client)
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.registerStorageRoot(RegisterStorageRootRequest(path: volume.path)))
        guard case .snapshot(let snapshot)? = await recorder.waitFor(matching: {
            if case .snapshot(let snap) = $0 { return snap.storageRoots.contains(where: { $0.kind == .external }) }
            return false
        }) else {
            Issue.record("volume should register")
            return
        }
        let ext = try #require(snapshot.storageRoots.first { $0.kind == .external })
        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path,
            name: "curie",
            storageRootID: ext.id
        )))
        guard case .workspaceAdded(let created)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            Issue.record("workspace should be created")
            return
        }
        let originalPath = created.worktreePath

        disk.reachable.remove(volume.path)
        disk.reachable.remove(volume.standardizedFileURL.path)
        await client.send(.rescanStorageRoots)
        guard case .snapshot(let after)? = await recorder.waitFor(matching: {
            if case .snapshot(let snap) = $0 {
                return snap.workspaces.contains { $0.id == created.id && $0.isStorageOffline }
            }
            return false
        }) else {
            Issue.record("unplug should mark the workspace offline")
            return
        }
        let offline = try #require(after.workspaces.first { $0.id == created.id })
        #expect(offline.worktreePath == originalPath)
        #expect(offline.isStorageOffline)

        let beforeSend = await recorder.checkpoint()
        await client.send(.sendMessage(SendMessageRequest(
            workspaceID: created.id, text: "hello"
        )))
        guard case .commandFailed(let failure)? = await recorder.waitFor(
            after: beforeSend,
            matching: {
                if case .commandFailed = $0 { return true }
                return false
            }
        ) else {
            Issue.record("sending to an offline workspace must fail cleanly")
            return
        }
        #expect(failure.message.contains("isn’t connected") || failure.message.contains("isn't connected"))
    }

    @Test func newWorkFallsBackToTheInjectedInternalRootWhenExternalIsOffline() async throws {
        let fixture = try await GitFixture.initialized()
        let volume = fixture.root.appendingPathComponent("volume", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let disk = FakeDisk(reachable: [
            OreHome.directory.standardizedFileURL.path, volume.path,
        ])

        let client = InProcessCoreClient(
            store: try OreStore(),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot,
            volumeProbe: disk.probe
        )
        let recorder = CoreEventRecorder(client)
        await client.send(.addRepository(path: fixture.repository.path))
        await client.send(.registerStorageRoot(RegisterStorageRootRequest(
            path: volume.path, preferForNewWork: true
        )))
        _ = await recorder.waitFor(matching: {
            if case .snapshot(let snap) = $0 { return snap.storageRoots.contains(where: \.isPreferred) }
            return false
        })

        disk.reachable.remove(volume.path)
        disk.reachable.remove(volume.standardizedFileURL.path)
        await client.send(.rescanStorageRoots)
        _ = await recorder.waitFor(matching: {
            if case .snapshot(let snap) = $0 {
                return snap.storageRoots.contains { $0.kind == .external && !$0.isAvailable }
            }
            return false
        })

        await client.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path,
            name: "fallback"
        )))
        guard case .workspaceAdded(let summary)? = await recorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            Issue.record("create should fall back to This Mac")
            return
        }
        #expect(summary.worktreePath.hasPrefix(fixture.worktreeRoot.path))
        #expect(summary.storage?.rootID == .internalDefault)
        #expect(!summary.worktreePath.hasPrefix(volume.path))
    }
}

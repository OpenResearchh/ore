import Foundation
import Testing

@testable import OreCore
@testable import OreHarness
@testable import OrePersistence
@testable import OreProtocol
@testable import OreSupport

/// Launch reuses what the previous run learned about the harnesses, and puts
/// the sidebar on screen before any engine has started.
struct CoreStartupTests {
    // MARK: - Discovery cache

    private let codexModels = [AgentModel(id: "gpt-cached", displayName: "Cached")]

    @Test func aCatalogIsReusedOnlyForTheSameCLIVersionWhileFresh() {
        let now = Date()
        var cache = HarnessDiscoveryCache()
        cache.storeCatalog(codexModels, for: .codex, harnessVersion: "codex-cli 1.2.0", now: now)

        #expect(cache.catalog(
            for: .codex, harnessVersion: "codex-cli 1.2.0", now: now.addingTimeInterval(60)
        ) == codexModels)
        // An upgraded CLI may offer different models.
        #expect(cache.catalog(
            for: .codex, harnessVersion: "codex-cli 1.3.0", now: now.addingTimeInterval(60)
        ) == nil)
        #expect(cache.catalog(
            for: .codex,
            harnessVersion: "codex-cli 1.2.0",
            now: now.addingTimeInterval(HarnessDiscoveryCache.catalogLifetime + 1)
        ) == nil)
        // A clock that moved backwards can't make an entry look fresh forever.
        #expect(cache.catalog(
            for: .codex, harnessVersion: "codex-cli 1.2.0", now: now.addingTimeInterval(-60)
        ) == nil)
    }

    @Test func freeCatalogsAndEmptyOnesAreNeverCached() {
        let now = Date()
        var cache = HarnessDiscoveryCache()
        cache.storeCatalog(
            [AgentModel(id: "claude-x", displayName: "X")],
            for: .claudeCode, harnessVersion: "1.0", now: now
        )
        cache.storeCatalog([], for: .cursorAgent, harnessVersion: "1.0", now: now)

        #expect(cache.catalogs.isEmpty)
        #expect(cache.catalog(for: .claudeCode, harnessVersion: "1.0", now: now) == nil)
    }

    @Test func anUpdateCheckIsAdoptedOnlyForTheSameInstalledVersions() {
        let now = Date()
        var cache = HarnessDiscoveryCache()
        cache.lastUpdateCheck = now
        cache.updates = [HarnessUpdateStatus(
            kind: .codex, installedVersion: "1.2.0", latestVersion: "1.3.0"
        )]
        let installed = [HarnessProbeResult(
            kind: .codex, executablePath: "/bin/codex",
            version: "codex-cli 1.2.0", authState: .authenticated
        )]

        #expect(cache.updates(matching: installed, now: now.addingTimeInterval(60)) == cache.updates)

        let upgraded = [HarnessProbeResult(
            kind: .codex, executablePath: "/bin/codex",
            version: "codex-cli 1.3.0", authState: .authenticated
        )]
        #expect(cache.updates(matching: upgraded, now: now) == nil)

        let newlyInstalled = installed + [HarnessProbeResult(
            kind: .claudeCode, executablePath: "/bin/claude",
            version: "2.0.1", authState: .authenticated
        )]
        #expect(cache.updates(matching: newlyInstalled, now: now) == nil)

        #expect(cache.updates(
            matching: installed,
            now: now.addingTimeInterval(InProcessCoreClient.harnessUpdateCheckInterval + 1)
        ) == nil)
    }

    @Test func theCacheRoundTripsAndAnUnreadableFileIsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ore-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("harness-cache.json")

        var cache = HarnessDiscoveryCache()
        cache.storeCatalog(codexModels, for: .codex, harnessVersion: "1.0", now: Date())
        cache.lastUpdateCheck = Date()
        cache.updates = [HarnessUpdateStatus(kind: .codex, installedVersion: "1.0")]
        cache.save(to: url)
        #expect(HarnessDiscoveryCache.load(from: url) == cache)

        try Data("not json".utf8).write(to: url)
        #expect(HarnessDiscoveryCache.load(from: url) == HarnessDiscoveryCache())
    }

    @Test func onlyQuotaErrorAndTurnEventsCarryHarnessHealth() {
        #expect(InProcessCoreClient.carriesHarnessHealth(
            .rateLimit(RateLimitReport(status: .allowed))
        ))
        #expect(!InProcessCoreClient.carriesHarnessHealth(.statusChanged(.idle)))
    }

    // MARK: - Launch

    @Test func launchPublishesStoredRowsFirstThenEachEngine() async throws {
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")

        let first = InProcessCoreClient(
            store: try OreStore(path: databasePath),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let firstRecorder = CoreEventRecorder(first)
        await first.send(.addRepository(path: fixture.repository.path))
        await first.send(.createWorkspace(CreateWorkspaceRequest(
            repositoryPath: fixture.repository.path, name: "relaunched"
        )))
        guard case .workspaceAdded(let workspace)? = await firstRecorder.waitFor(matching: {
            if case .workspaceAdded = $0 { return true }
            return false
        }) else {
            Issue.record("no workspace")
            return
        }
        await first.shutdown()

        let second = InProcessCoreClient(
            store: try OreStore(path: databasePath),
            harnessRegistry: HarnessRegistry(harnesses: []),
            worktreeRoot: fixture.worktreeRoot
        )
        let recorder = CoreEventRecorder(second)
        try await second.start()

        _ = await recorder.waitFor {
            if case .workspaceUpdated(let summary) = $0 { return summary.id == workspace.id }
            return false
        }
        let events = await recorder.all()
        let snapshotIndex = events.firstIndex {
            if case .snapshot(let snapshot) = $0 {
                return snapshot.workspaces.contains { $0.id == workspace.id }
            }
            return false
        }
        let updateIndex = events.firstIndex {
            if case .workspaceUpdated(let summary) = $0 { return summary.id == workspace.id }
            return false
        }
        #expect(snapshotIndex != nil)
        #expect(updateIndex != nil)
        if let snapshotIndex, let updateIndex {
            // The snapshot replaces the client's whole list, so it must never
            // land on top of live state an engine already published.
            #expect(snapshotIndex < updateIndex)
        }
        // Only the launch snapshot: engines report their own rows.
        #expect(events.filter { if case .snapshot = $0 { return true }; return false }.count == 1)

        await second.shutdown()
    }

    @Test func aRelaunchReusesTheCatalogAndUpdateCheckInsteadOfSpawning() async throws {
        let fixture = try await GitFixture.initialized()
        let databasePath = fixture.root.appendingPathComponent("ore.sqlite")
        // A check the last run made, against the version installed now, so the
        // launch path never reaches a real registry from the test.
        var seeded = HarnessDiscoveryCache()
        seeded.lastUpdateCheck = Date()
        seeded.updates = [HarnessUpdateStatus(
            kind: .codex, installedVersion: "1.0", latestVersion: "1.1"
        )]
        seeded.save(to: fixture.root.appendingPathComponent("harness-cache.json"))

        let cold = CountingCatalogHarness(kind: .codex, models: codexModels)
        let first = InProcessCoreClient(
            store: try OreStore(path: databasePath),
            harnessRegistry: HarnessRegistry(harnesses: [cold]),
            worktreeRoot: fixture.worktreeRoot
        )
        let firstRecorder = CoreEventRecorder(first)
        try await first.start()
        let adopted = await firstRecorder.waitFor {
            if case .harnessUpdatesChecked(let statuses) = $0 {
                return statuses.first?.latestVersion == "1.1"
            }
            return false
        }
        #expect(adopted != nil)
        _ = await firstRecorder.waitFor {
            if case .modelCatalogUpdated(.codex, _) = $0 { return true }
            return false
        }
        #expect(cold.discoveries == 1)
        let cacheURL = fixture.root.appendingPathComponent("harness-cache.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline,
              HarnessDiscoveryCache.load(from: cacheURL).catalogs["codex"] == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
        await first.shutdown()

        let warm = CountingCatalogHarness(kind: .codex, models: [])
        let second = InProcessCoreClient(
            store: try OreStore(path: databasePath),
            harnessRegistry: HarnessRegistry(harnesses: [warm]),
            worktreeRoot: fixture.worktreeRoot
        )
        let secondRecorder = CoreEventRecorder(second)
        try await second.start()
        let reused = await secondRecorder.waitFor {
            if case .modelCatalogUpdated(.codex, let models) = $0 {
                return models.map(\.id) == ["gpt-cached"]
            }
            return false
        }
        #expect(reused != nil)
        #expect(warm.discoveries == 0)

        await second.shutdown()
    }
}

/// Reports a fixed catalog and counts how often it was asked for one.
private final class CountingCatalogHarness: AgentHarness, @unchecked Sendable {
    let kind: HarnessKind
    let capabilities = HarnessCapabilities()
    let supportsAuxiliarySessions = false
    private let models: [AgentModel]
    private let count = Lockbox(0)

    init(kind: HarnessKind, models: [AgentModel]) {
        self.kind = kind
        self.models = models
    }

    var discoveries: Int { count.get() }

    func probe() async -> HarnessProbeResult {
        HarnessProbeResult(
            kind: kind, executablePath: "/fake/\(kind.rawValue)",
            version: "1.0", authState: .authenticated
        )
    }

    func discoverModels() async -> [AgentModel] {
        count.withLock { $0 += 1 }
        return models
    }

    func makeSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        throw HarnessError.unsupportedCapability("sessions")
    }
}

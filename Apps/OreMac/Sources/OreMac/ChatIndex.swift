import Foundation
import Observation
import OreProtocol

/// One workspace's chats, sorted by creation, independently observable.
///
/// Views ask for a workspace's tabs dozens of times per render. Filtering and
/// sorting the whole fleet's summaries on each call put that on every frame,
/// and reading the one flat array meant any chat anywhere invalidated every
/// tab strip. Each list is only reassigned when its contents really change.
@MainActor
@Observable
final class WorkspaceChats {
    /// Every chat, closed ones included, oldest first.
    private(set) var all: [ChatSummary] = []
    /// The open subset of `all`, in the same order.
    private(set) var open: [ChatSummary] = []

    fileprivate func assign(_ chats: [ChatSummary]) {
        guard chats != all else { return }
        all = chats
        let nextOpen = chats.filter { !$0.isClosed }
        if nextOpen != open { open = nextOpen }
    }
}

/// Per-workspace chat lists kept current as summaries arrive, so reads are a
/// dictionary lookup instead of a filter and sort over every chat.
///
/// Not observable itself: the lists are. `AppModel` writes it alongside every
/// write to `chatSummaries`.
@MainActor
final class ChatIndex {
    private var lists: [WorkspaceID: WorkspaceChats] = [:]
    private var owners: [ChatID: WorkspaceID] = [:]

    /// Created on first read so a view that asks before any chat arrives is
    /// still subscribed to the list that later fills.
    func list(for workspaceID: WorkspaceID) -> WorkspaceChats {
        if let existing = lists[workspaceID] { return existing }
        let created = WorkspaceChats()
        lists[workspaceID] = created
        return created
    }

    func chats(for workspaceID: WorkspaceID, includeClosed: Bool) -> [ChatSummary] {
        let list = list(for: workspaceID)
        return includeClosed ? list.all : list.open
    }

    /// Reads through the owning workspace's observable list, so a view asking
    /// for a title is invalidated when that title changes.
    func summary(for chatID: ChatID) -> ChatSummary? {
        guard let workspaceID = owners[chatID] else { return nil }
        return lists[workspaceID]?.all.first { $0.id == chatID }
    }

    func upsert(_ summary: ChatSummary) {
        if let previous = owners[summary.id], previous != summary.workspaceID {
            removeFromList(summary.id, in: previous)
        }
        owners[summary.id] = summary.workspaceID
        let list = list(for: summary.workspaceID)
        var chats = list.all
        if let index = chats.firstIndex(where: { $0.id == summary.id }) {
            if chats[index] == summary { return }
            if chats[index].createdAt == summary.createdAt {
                chats[index] = summary
                list.assign(chats)
                return
            }
            chats.remove(at: index)
        }
        // After every chat created at or before it: the place a stable sort of
        // arrival order puts it, which is what the old filter-and-sort did.
        let position = chats.firstIndex { $0.createdAt > summary.createdAt } ?? chats.endIndex
        chats.insert(summary, at: position)
        list.assign(chats)
    }

    func remove(_ chatID: ChatID) {
        guard let workspaceID = owners.removeValue(forKey: chatID) else { return }
        removeFromList(chatID, in: workspaceID)
    }

    /// Returns the chats the workspace had, so their state can be released.
    @discardableResult
    func removeWorkspace(_ workspaceID: WorkspaceID) -> [ChatID] {
        guard let list = lists.removeValue(forKey: workspaceID) else { return [] }
        let removed = list.all.map(\.id)
        for chatID in removed { owners.removeValue(forKey: chatID) }
        // Emptied rather than just dropped, so a view still holding it redraws.
        list.assign([])
        return removed
    }

    /// A full snapshot: every list is rebuilt, and lists whose contents did not
    /// move are left untouched.
    func replaceAll(_ summaries: [ChatSummary]) {
        var grouped: [WorkspaceID: [ChatSummary]] = [:]
        var nextOwners: [ChatID: WorkspaceID] = [:]
        for summary in summaries {
            if let previous = nextOwners[summary.id] {
                // A duplicate id: the last copy wins, as it does in the owner map.
                grouped[previous]?.removeAll { $0.id == summary.id }
            }
            nextOwners[summary.id] = summary.workspaceID
            grouped[summary.workspaceID, default: []].append(summary)
        }
        owners = nextOwners
        for (workspaceID, list) in lists where grouped[workspaceID] == nil {
            list.assign([])
        }
        for (workspaceID, chats) in grouped {
            // `sorted` is stable, so equal timestamps keep arrival order.
            list(for: workspaceID).assign(chats.sorted { $0.createdAt < $1.createdAt })
        }
    }

    private func removeFromList(_ chatID: ChatID, in workspaceID: WorkspaceID) {
        guard let list = lists[workspaceID] else { return }
        var chats = list.all
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats.remove(at: index)
        list.assign(chats)
    }
}

/// Collapses background diff refreshes to one per workspace at a time.
///
/// Every git-status bump used to start its own `git diff`, and an agent
/// writing files bumps it many times a second. A request that lands while one
/// is running is remembered once, and runs after the current read finishes.
struct RefreshGate<Key: Hashable> {
    private var inFlight: Set<Key> = []
    private var trailing: Set<Key> = []

    /// True when the caller should start a refresh now; false when one is
    /// already running and this request was folded into its trailing run.
    mutating func request(_ key: Key) -> Bool {
        guard inFlight.insert(key).inserted else {
            trailing.insert(key)
            return false
        }
        return true
    }

    /// Called when a refresh finishes. True means a request arrived meanwhile:
    /// the key stays in flight and the caller should run once more.
    mutating func finish(_ key: Key) -> Bool {
        if trailing.remove(key) != nil { return true }
        inFlight.remove(key)
        return false
    }

    func isInFlight(_ key: Key) -> Bool {
        inFlight.contains(key)
    }

    mutating func cancel(_ key: Key) {
        inFlight.remove(key)
        trailing.remove(key)
    }
}

import AppKit
import Foundation

/// Watches for volumes appearing, disappearing, or renaming, and asks the
/// core to rescan storage roots.
///
/// Mount notifications are how an unplugged SSD comes back without the user
/// having to reopen Settings. The core owns availability; this only pokes it.
@MainActor
final class StorageVolumeMonitor {
    static let shared = StorageVolumeMonitor()

    var onChange: (() -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onChange?()
                }
            })
        }
    }
}

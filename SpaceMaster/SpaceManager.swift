import AppKit
import Foundation

@MainActor
final class SpaceManager: SpaceSwitching {
    private enum Constants {
        static let snapshotCapacity = Int(ISSSpaceSnapshotMaxEntries)
    }

    private var initialized = false

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func initialize() {
        guard !initialized else { return }
        initialized = iss_init()
    }

    func destroy() {
        guard initialized else { return }
        iss_destroy()
        initialized = false
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func menubarSnapshot() -> MenubarSpaceSnapshot? {
        snapshot(useCursorDisplay: false)
    }

    func cursorSnapshot() -> MenubarSpaceSnapshot? {
        snapshot(useCursorDisplay: true)
    }

    private func snapshot(useCursorDisplay: Bool) -> MenubarSpaceSnapshot? {
        var snapshot = ISSSpaceSnapshot()
        let entries = UnsafeMutablePointer<ISSSpaceSnapshotEntry>.allocate(capacity: Constants.snapshotCapacity)
        defer { entries.deallocate() }

        let didCopySnapshot = if useCursorDisplay {
            iss_copy_cursor_space_snapshot(
                &snapshot,
                entries,
                UInt32(Constants.snapshotCapacity)
            )
        } else {
            iss_copy_menubar_space_snapshot(
                &snapshot,
                entries,
                UInt32(Constants.snapshotCapacity)
            )
        }

        guard didCopySnapshot, snapshot.spaceCount > 0 else {
            return nil
        }

        var spaces: [MenubarSpace] = []
        spaces.reserveCapacity(Int(snapshot.spaceCount))

        for index in 0..<Int(snapshot.spaceCount) {
            let entry = entries[index]
            let identity = MenubarSpaceIdentity(
                uuid: entry.uuidString,
                id64: UInt64(entry.id64)
            )
            spaces.append(MenubarSpace(identity: identity))
        }

        guard spaces.indices.contains(Int(snapshot.currentIndex)) else {
            return nil
        }

        return MenubarSpaceSnapshot(
            currentIndex: Int(snapshot.currentIndex),
            spaces: spaces
        )
    }

    func cursorSpaceInfo() -> (currentIndex: Int, spaceCount: Int)? {
        var info = ISSSpaceInfo()
        guard iss_get_space_info(&info), info.spaceCount > 0 else {
            return nil
        }

        return (Int(info.currentIndex), Int(info.spaceCount))
    }

    @discardableResult
    func switchToMenubarSpace(_ spaceNumber: Int) -> Bool {
        guard spaceNumber > 0 else { return false }
        guard isAccessibilityTrusted else {
            requestAccessibilityPermission()
            return false
        }
        guard ensureInitialized() else { return false }

        return iss_switch_to_index_on_menubar(UInt32(spaceNumber - 1))
    }

    @discardableResult
    func switchToSpace(_ spaceNumber: Int, onScreen screenIndex: Int = 0) -> Bool {
        guard spaceNumber > 0 else { return false }
        guard isAccessibilityTrusted else {
            requestAccessibilityPermission()
            return false
        }
        guard ensureInitialized() else { return false }

        _ = screenIndex
        return iss_switch_to_index(UInt32(spaceNumber - 1))
    }

    private func ensureInitialized() -> Bool {
        if initialized {
            return true
        }

        initialized = iss_init()
        return initialized
    }
}

private extension ISSSpaceSnapshotEntry {
    var uuidString: String? {
        withUnsafePointer(to: self) { entryPointer in
            guard let uuidCString = iss_space_snapshot_entry_uuid(entryPointer) else {
                return nil
            }

            return String(cString: uuidCString)
        }
    }
}

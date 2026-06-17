import Foundation

struct MenubarSpaceIdentity: Hashable {
    let uuid: String?
    let id64: UInt64

    var stableStorageKey: String {
        if let uuid, !uuid.isEmpty {
            return "uuid:\(uuid)"
        }

        return "id64:\(id64)"
    }

    var aliasKey: String {
        stableStorageKey
    }
}

struct MenubarSpace: Hashable {
    let identity: MenubarSpaceIdentity
}

struct MenubarSpaceSnapshot {
    let currentIndex: Int
    let spaces: [MenubarSpace]

    var currentSpace: MenubarSpace? {
        space(at: currentIndex)
    }

    var currentSpaceNumber: Int {
        currentIndex + 1
    }

    var spaceCount: Int {
        spaces.count
    }

    func space(at index: Int) -> MenubarSpace? {
        guard spaces.indices.contains(index) else { return nil }
        return spaces[index]
    }
}

@MainActor
protocol SpaceSwitching: AnyObject {
    var isAccessibilityTrusted: Bool { get }

    func initialize()
    func destroy()
    func requestAccessibilityPermission()
    func menubarSnapshot() -> MenubarSpaceSnapshot?
    func cursorSnapshot() -> MenubarSpaceSnapshot?
    func cursorSpaceInfo() -> (currentIndex: Int, spaceCount: Int)?
    func switchToPreviousSpace() -> Bool
    func switchToNextSpace() -> Bool
    func switchToMenubarSpace(_ spaceNumber: Int) -> Bool
    func switchToSpace(_ spaceNumber: Int, onScreen screenIndex: Int) -> Bool
}

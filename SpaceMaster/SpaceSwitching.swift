import Foundation

@MainActor
protocol SpaceSwitching: AnyObject {
    var isAccessibilityTrusted: Bool { get }

    func initialize()
    func destroy()
    func requestAccessibilityPermission()
    func spaceInfo() -> (currentIndex: Int, spaceCount: Int)?
    func cursorSpaceInfo() -> (currentIndex: Int, spaceCount: Int)?
    func switchToMenubarSpace(_ spaceNumber: Int) -> Bool
    func switchToSpace(_ spaceNumber: Int, onScreen screenIndex: Int) -> Bool
}

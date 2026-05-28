import AppKit
import Foundation

@MainActor
final class SpaceManager: SpaceSwitching {
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

    func spaceInfo() -> (currentIndex: Int, spaceCount: Int)? {
        var info = ISSSpaceInfo()
        guard iss_get_menubar_space_info(&info), info.spaceCount > 0 else {
            return nil
        }

        return (Int(info.currentIndex), Int(info.spaceCount))
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

        activateScreen(screenIndex)
        return iss_switch_to_index(UInt32(spaceNumber - 1))
    }

    private func ensureInitialized() -> Bool {
        if initialized {
            return true
        }

        initialized = iss_init()
        return initialized
    }

    private func activateScreen(_ screenIndex: Int) {
        let screens = NSScreen.screens
        guard screens.indices.contains(screenIndex) else { return }

        let screen = screens[screenIndex]
        let primaryHeight = screens.first?.frame.height ?? screen.frame.height
        let center = CGPoint(x: screen.frame.midX, y: primaryHeight - screen.frame.midY)
        CGWarpMouseCursorPosition(center)
    }
}

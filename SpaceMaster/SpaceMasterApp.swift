import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spaceSwitcher: SpaceSwitching = SpaceManager()
    private let titleResolver = SpaceTitleResolver()
    private var statusItemController: StatusItemController?
    private var spaceOverlayCoordinator: SpaceOverlayCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        spaceSwitcher.initialize()
        statusItemController = StatusItemController(
            spaceSwitcher: spaceSwitcher,
            titleResolver: titleResolver
        )
        spaceOverlayCoordinator = SpaceOverlayCoordinator(
            spaceSwitcher: spaceSwitcher,
            titleResolver: titleResolver
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        spaceSwitcher.destroy()
    }
}

@main
struct SpaceMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

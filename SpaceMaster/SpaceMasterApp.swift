import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let spaceSwitcher: SpaceSwitching = SpaceManager()
    private let titleResolver = SpaceTitleResolver()
    private let hotkeyStore = SpaceHotkeyStore()
    private var hotkeyRegistrar: SpaceHotkeyRegistrar?
    private var instantSwipeController: FourFingerInstantSwipeController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        spaceSwitcher.initialize()
        let instantSwipeController = FourFingerInstantSwipeController(
            spaceSwitcher: spaceSwitcher
        )
        self.instantSwipeController = instantSwipeController
        let hotkeyRegistrar = SpaceHotkeyRegistrar(
            store: hotkeyStore,
            spaceSwitcher: spaceSwitcher
        )
        self.hotkeyRegistrar = hotkeyRegistrar
        hotkeyRegistrar.refresh()
        statusItemController = StatusItemController(
            spaceSwitcher: spaceSwitcher,
            titleResolver: titleResolver,
            hotkeyStore: hotkeyStore,
            hotkeyRegistrar: hotkeyRegistrar,
            instantSwipeController: instantSwipeController
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        instantSwipeController?.stop()
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

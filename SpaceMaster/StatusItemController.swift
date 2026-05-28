import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private enum Constants {
        static let appName = "SpaceMaster"
        static let unavailableTitle = "Spaces"
    }

    private let spaceSwitcher: SpaceSwitching
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(spaceSwitcher: SpaceSwitching) {
        self.spaceSwitcher = spaceSwitcher
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = nil
            button.title = Constants.unavailableTitle
            button.toolTip = Constants.appName
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let canSwitchSpaces = spaceSwitcher.isAccessibilityTrusted

        if !canSwitchSpaces {
            let permissionItem = NSMenuItem(
                title: "Accessibility Permission Required",
                action: nil,
                keyEquivalent: ""
            )
            permissionItem.isEnabled = false
            menu.addItem(permissionItem)
            menu.addItem(menuItem(title: "Grant Accessibility Permission", action: #selector(requestAccessibilityPermission)))
            menu.addItem(.separator())
        }

        if let info = spaceSwitcher.spaceInfo() {
            updateStatusItemTitle(for: info)
            addSpaceInfoItems(info, canSwitchSpaces: canSwitchSpaces)
        } else {
            updateStatusItemTitle(for: nil)
            let item = NSMenuItem(title: "Spaces unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Refresh", action: #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit SpaceMaster", action: #selector(quit)))
    }

    private func addSpaceInfoItems(_ info: (currentIndex: Int, spaceCount: Int), canSwitchSpaces: Bool) {
        let currentSpaceNumber = info.currentIndex + 1
        let summary = NSMenuItem(
            title: "\(spaceTitle(for: currentSpaceNumber)) of \(info.spaceCount)",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        for spaceNumber in 1...info.spaceCount {
            let item = menuItem(title: spaceTitle(for: spaceNumber), action: #selector(switchSpace(_:)))
            item.representedObject = spaceNumber
            item.state = spaceNumber == currentSpaceNumber ? .on : .off
            item.isEnabled = canSwitchSpaces
            menu.addItem(item)
        }
    }

    private func updateStatusItemTitle(for info: (currentIndex: Int, spaceCount: Int)?) {
        guard let button = statusItem.button else { return }
        guard let info else {
            button.title = Constants.unavailableTitle
            return
        }

        button.title = spaceTitle(for: info.currentIndex + 1)
    }

    private func spaceTitle(for spaceNumber: Int) -> String {
        "Desktop \(spaceNumber)"
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func switchSpace(_ sender: NSMenuItem) {
        guard let spaceNumber = sender.representedObject as? Int else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.performSwitch(to: spaceNumber)
        }
    }

    private func performSwitch(to spaceNumber: Int) {
        guard spaceSwitcher.switchToMenubarSpace(spaceNumber) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.rebuildMenu()
            }
            return
        }

        waitUntilOnSpace(spaceNumber, timeout: 3.0) { [weak self] in
            self?.rebuildMenu()
        }
    }

    private func waitUntilOnSpace(_ targetSpace: Int, timeout: TimeInterval, completion: @escaping () -> Void) {
        let targetIndex = targetSpace - 1
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if let info = spaceSwitcher.spaceInfo(),
               info.currentIndex == targetIndex {
                completion()
                return
            }

            guard Date() < deadline else {
                completion()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                poll()
            }
        }

        poll()
    }

    @objc private func requestAccessibilityPermission() {
        spaceSwitcher.requestAccessibilityPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func refresh() {
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

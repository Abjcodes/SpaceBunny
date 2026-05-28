import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private enum Constants {
        static let appName = "SpaceMaster"
        static let unavailableTitle = "Spaces"
        static let renameMenuTitle = "Rename Current Space..."
        static let menuActionDelay = 0.15
    }

    private struct RenameTarget {
        let identity: MenubarSpaceIdentity
        let spaceNumber: Int
    }

    private let aliasStore = SpaceAliasStore()
    private let spaceSwitcher: SpaceSwitching
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

    init(spaceSwitcher: SpaceSwitching) {
        self.spaceSwitcher = spaceSwitcher
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        startObservingSystemChanges()
        rebuildMenu()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        workspaceNotificationCenter.removeObserver(self)
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

    private func startObservingSystemChanges() {
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(handleSystemStateChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemStateChange),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let canSwitchSpaces = spaceSwitcher.isAccessibilityTrusted
        let snapshot = spaceSwitcher.menubarSnapshot()

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

        if let snapshot {
            updateStatusItemTitle(for: snapshot)
            addSpaceInfoItems(snapshot, canSwitchSpaces: canSwitchSpaces)
        } else {
            updateStatusItemTitle(for: nil)
            let item = NSMenuItem(title: "Spaces unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let renameItem = menuItem(title: Constants.renameMenuTitle, action: #selector(renameCurrentSpace(_:)))
        if let renameTarget = renameTarget(from: snapshot) {
            renameItem.representedObject = renameTarget
            renameItem.isEnabled = true
        } else {
            renameItem.isEnabled = false
        }
        menu.addItem(renameItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Refresh", action: #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit SpaceMaster", action: #selector(quit)))
    }

    private func renameTarget(from snapshot: MenubarSpaceSnapshot?) -> RenameTarget? {
        guard let snapshot, let currentSpace = snapshot.currentSpace else {
            return nil
        }

        return RenameTarget(
            identity: currentSpace.identity,
            spaceNumber: snapshot.currentSpaceNumber
        )
    }

    private func addSpaceInfoItems(_ snapshot: MenubarSpaceSnapshot, canSwitchSpaces: Bool) {
        let summary = NSMenuItem(
            title: "\(spaceTitle(for: snapshot.currentSpace, spaceNumber: snapshot.currentSpaceNumber)) of \(snapshot.spaceCount)",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())

        for (index, space) in snapshot.spaces.enumerated() {
            let spaceNumber = index + 1
            let item = menuItem(
                title: spaceTitle(for: space, spaceNumber: spaceNumber),
                action: #selector(switchSpace(_:))
            )
            item.representedObject = spaceNumber
            item.state = spaceNumber == snapshot.currentSpaceNumber ? .on : .off
            item.isEnabled = canSwitchSpaces
            menu.addItem(item)
        }
    }

    private func updateStatusItemTitle(for snapshot: MenubarSpaceSnapshot?) {
        guard let button = statusItem.button else { return }
        guard let snapshot else {
            button.title = Constants.unavailableTitle
            return
        }

        button.title = spaceTitle(
            for: snapshot.currentSpace,
            spaceNumber: snapshot.currentSpaceNumber
        )
    }

    private func spaceTitle(for space: MenubarSpace?, spaceNumber: Int) -> String {
        guard let space else {
            return defaultSpaceTitle(for: spaceNumber)
        }

        return aliasStore.alias(for: space.identity) ?? defaultSpaceTitle(for: spaceNumber)
    }

    private func defaultSpaceTitle(for spaceNumber: Int) -> String {
        "Desktop \(spaceNumber)"
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func renameCurrentSpace(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? RenameTarget else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.menuActionDelay) { [weak self] in
            self?.presentRenamePrompt(for: target)
        }
    }

    private func presentRenamePrompt(for target: RenameTarget) {
        let alert = NSAlert()
        alert.messageText = "Rename \(defaultSpaceTitle(for: target.spaceNumber))"
        alert.informativeText = "Enter a custom name for this space. Leave it blank to clear the alias."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = defaultSpaceTitle(for: target.spaceNumber)
        textField.stringValue = aliasStore.alias(for: target.identity) ?? ""
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let alias = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        aliasStore.setAlias(alias.isEmpty ? nil : alias, for: target.identity)
        rebuildMenu()
    }

    @objc private func switchSpace(_ sender: NSMenuItem) {
        guard let spaceNumber = sender.representedObject as? Int else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.menuActionDelay) { [weak self] in
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
            if let snapshot = spaceSwitcher.menubarSnapshot(),
               snapshot.currentIndex == targetIndex {
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

    @objc private func handleSystemStateChange() {
        rebuildMenu()
    }

    @objc private func refresh() {
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private final class SpaceAliasStore {
    private enum Keys {
        static let aliases = "spaceAliasesByStableID"
        static let legacyNumberedAliases = "spaceAliases"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clearLegacyAliasesIfNeeded()
    }

    func alias(for identity: MenubarSpaceIdentity) -> String? {
        aliases()[identity.aliasKey]
    }

    func setAlias(_ alias: String?, for identity: MenubarSpaceIdentity) {
        var updatedAliases = aliases()
        let key = identity.aliasKey

        if let alias {
            updatedAliases[key] = alias
        } else {
            updatedAliases.removeValue(forKey: key)
        }

        if updatedAliases.isEmpty {
            defaults.removeObject(forKey: Keys.aliases)
        } else {
            defaults.set(updatedAliases, forKey: Keys.aliases)
        }
    }

    private func clearLegacyAliasesIfNeeded() {
        guard defaults.object(forKey: Keys.legacyNumberedAliases) != nil else {
            return
        }

        defaults.removeObject(forKey: Keys.legacyNumberedAliases)
    }

    private func aliases() -> [String: String] {
        defaults.dictionary(forKey: Keys.aliases) as? [String: String] ?? [:]
    }
}

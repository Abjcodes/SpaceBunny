import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private enum Constants {
        static let appName = "SpaceMaster"
        static let unavailableTitle = "Spaces"
        static let renameMenuTitle = "Rename Current Space..."
        static let assignHotkeyMenuTitle = "Assign Hotkey..."
        static let menuActionDelay = 0.15
        static let autoNameRefreshDelays: [TimeInterval] = [0.2, 0.35, 0.5]
        static let cursorRefreshInterval: TimeInterval = 0.25
    }

    private struct SpaceActionTarget {
        let identity: MenubarSpaceIdentity
        let spaceNumber: Int
    }

    private let fullScreenSpaceNameDetector = FullScreenSpaceNameDetector()
    private let spaceSwitcher: SpaceSwitching
    private let titleResolver: SpaceTitleResolver
    private let hotkeyStore: SpaceHotkeyStore
    private let hotkeyRegistrar: SpaceHotkeyRegistrar
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
    private var autoNameRefreshGeneration = 0
    private var cursorRefreshTimer: Timer?
    private var lastCursorSnapshot: MenubarSpaceSnapshot?

    init(
        spaceSwitcher: SpaceSwitching,
        titleResolver: SpaceTitleResolver,
        hotkeyStore: SpaceHotkeyStore,
        hotkeyRegistrar: SpaceHotkeyRegistrar
    ) {
        self.spaceSwitcher = spaceSwitcher
        self.titleResolver = titleResolver
        self.hotkeyStore = hotkeyStore
        self.hotkeyRegistrar = hotkeyRegistrar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        startObservingSystemChanges()
        startCursorRefreshTimer()
        rebuildMenu()
        scheduleAutomaticNameRefresh()
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
            selector: #selector(handleActiveSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func startCursorRefreshTimer() {
        let timer = Timer.scheduledTimer(
            withTimeInterval: Constants.cursorRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCursorSnapshot()
            }
        }
        timer.tolerance = 0.05
        cursorRefreshTimer = timer
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let canSwitchSpaces = spaceSwitcher.isAccessibilityTrusted
        let snapshot = currentSnapshot()
        lastCursorSnapshot = snapshot

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
        let actionTarget = spaceActionTarget(from: snapshot)
        let renameItem = menuItem(title: Constants.renameMenuTitle, action: #selector(renameCurrentSpace(_:)))
        if let actionTarget {
            renameItem.representedObject = actionTarget
            renameItem.isEnabled = true
        } else {
            renameItem.isEnabled = false
        }
        menu.addItem(renameItem)

        let hotkeyItem = menuItem(title: Constants.assignHotkeyMenuTitle, action: #selector(assignHotkeyToCurrentSpace(_:)))
        if let actionTarget {
            hotkeyItem.representedObject = actionTarget
            hotkeyItem.isEnabled = true
        } else {
            hotkeyItem.isEnabled = false
        }
        menu.addItem(hotkeyItem)

        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Refresh", action: #selector(refresh)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit SpaceMaster", action: #selector(quit)))
    }

    private func currentSnapshot() -> MenubarSpaceSnapshot? {
        spaceSwitcher.cursorSnapshot() ?? spaceSwitcher.menubarSnapshot()
    }

    private func refreshCursorSnapshot() {
        let snapshot = currentSnapshot()
        let previousSnapshot = lastCursorSnapshot
        lastCursorSnapshot = snapshot

        guard snapshot?.currentIndex != previousSnapshot?.currentIndex
            || snapshot?.currentSpace?.identity != previousSnapshot?.currentSpace?.identity
            || (snapshot == nil) != (previousSnapshot == nil) else {
            return
        }

        updateStatusItemTitle(for: snapshot)
    }

    private func spaceActionTarget(from snapshot: MenubarSpaceSnapshot?) -> SpaceActionTarget? {
        guard let snapshot, let currentSpace = snapshot.currentSpace else {
            return nil
        }

        return SpaceActionTarget(
            identity: currentSpace.identity,
            spaceNumber: snapshot.currentSpaceNumber
        )
    }

    private func addSpaceInfoItems(_ snapshot: MenubarSpaceSnapshot, canSwitchSpaces: Bool) {
        let summary = NSMenuItem(
            title: "Current space: n\(spaceTitle(for: snapshot.currentSpace, spaceNumber: snapshot.currentSpaceNumber))",
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
            if let hotkey = hotkeyStore.hotkey(for: space.identity) {
                applyHotkey(hotkey, to: item)
            }
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
        displayTitle(for: space?.identity, spaceNumber: spaceNumber)
    }

    private func displayTitle(for identity: MenubarSpaceIdentity?, spaceNumber: Int) -> String {
        titleResolver.title(for: identity, spaceNumber: spaceNumber)
    }

    private func defaultSpaceTitle(for spaceNumber: Int) -> String {
        titleResolver.defaultTitle(for: spaceNumber)
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func applyHotkey(_ hotkey: SpaceHotkey, to item: NSMenuItem) {
        guard let keyEquivalent = hotkey.menuKeyEquivalent else { return }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = hotkey.menuModifierFlags
    }

    @objc private func renameCurrentSpace(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SpaceActionTarget else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.menuActionDelay) { [weak self] in
            self?.presentRenamePrompt(for: target)
        }
    }

    private func presentRenamePrompt(for target: SpaceActionTarget) {
        let alert = NSAlert()
        alert.messageText = "Rename \(displayTitle(for: target.identity, spaceNumber: target.spaceNumber))"
        alert.informativeText = "Enter a custom name for this space. Leave it blank to clear the alias."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.placeholderString = displayTitle(for: target.identity, spaceNumber: target.spaceNumber)
        textField.stringValue = titleResolver.manualAlias(for: target.identity) ?? ""
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let alias = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        titleResolver.setManualAlias(alias.isEmpty ? nil : alias, for: target.identity)
        rebuildMenu()
    }

    @objc private func assignHotkeyToCurrentSpace(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? SpaceActionTarget else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.menuActionDelay) { [weak self] in
            self?.presentHotkeyPrompt(for: target)
        }
    }

    private func presentHotkeyPrompt(for target: SpaceActionTarget) {
        let currentHotkey = hotkeyStore.hotkey(for: target.identity)
        let recorderView = HotkeyRecorderView(currentHotkey: currentHotkey)
        let title = displayTitle(for: target.identity, spaceNumber: target.spaceNumber)

        let alert = NSAlert()
        alert.messageText = "Assign Hotkey for \(title)"
        if let currentHotkey {
            alert.informativeText = "Current hotkey: \(currentHotkey.displayString). Press a modifier + key to replace it."
        } else {
            alert.informativeText = "Press a modifier + key to assign it to this space."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = recorderView
        alert.window.initialFirstResponder = recorderView

        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let hotkey = recorderView.hotkey else {
                presentWarning(
                    title: "No Hotkey Captured",
                    message: "Press a modifier + key before saving."
                )
                return
            }

            saveHotkey(hotkey, for: target)
        case .alertSecondButtonReturn:
            clearHotkey(for: target)
        default:
            break
        }
    }

    private func saveHotkey(_ hotkey: SpaceHotkey, for target: SpaceActionTarget) {
        let previousHotkey = hotkeyStore.hotkey(for: target.identity)

        do {
            try hotkeyStore.setHotkey(hotkey, for: target.identity)
        } catch SpaceHotkeyAssignmentError.duplicate(let existingStableStorageKey) {
            presentWarning(
                title: "Hotkey Already Assigned",
                message: "\(hotkey.displayString) is already assigned to \(spaceTitle(forStableStorageKey: existingStableStorageKey))."
            )
            return
        } catch {
            presentWarning(
                title: "Hotkey Not Saved",
                message: "SpaceMaster could not save this hotkey."
            )
            return
        }

        if let failure = hotkeyRegistrar.refresh().first(where: {
            $0.stableStorageKey == target.identity.stableStorageKey
        }) {
            restoreHotkey(previousHotkey, for: target.identity)
            hotkeyRegistrar.refresh()
            presentWarning(
                title: "Hotkey Unavailable",
                message: "\(failure.hotkey.displayString) could not be registered by macOS. Try a different shortcut. Status: \(failure.status)."
            )
            rebuildMenu()
            return
        }

        rebuildMenu()
    }

    private func clearHotkey(for target: SpaceActionTarget) {
        hotkeyStore.clearHotkey(for: target.identity)
        hotkeyRegistrar.refresh()
        rebuildMenu()
    }

    private func restoreHotkey(_ hotkey: SpaceHotkey?, for identity: MenubarSpaceIdentity) {
        if let hotkey {
            try? hotkeyStore.setHotkey(hotkey, for: identity)
        } else {
            hotkeyStore.clearHotkey(for: identity)
        }
    }

    private func spaceTitle(forStableStorageKey stableStorageKey: String) -> String {
        guard let snapshot = currentSnapshot(),
              let match = snapshot.spaces.enumerated().first(where: {
                  $0.element.identity.stableStorageKey == stableStorageKey
              }) else {
            return "another space"
        }

        return spaceTitle(for: match.element, spaceNumber: match.offset + 1)
    }

    private func presentWarning(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func switchSpace(_ sender: NSMenuItem) {
        guard let spaceNumber = sender.representedObject as? Int else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.menuActionDelay) { [weak self] in
            self?.performSwitch(to: spaceNumber)
        }
    }

    private func performSwitch(to spaceNumber: Int) {
        let screenIndex = currentScreenIndex()
        guard spaceSwitcher.switchToSpace(spaceNumber, onScreen: screenIndex) else {
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
            if let snapshot = spaceSwitcher.cursorSnapshot() ?? spaceSwitcher.menubarSnapshot(),
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
            self?.scheduleAutomaticNameRefresh()
        }
    }

    private func scheduleAutomaticNameRefresh() {
        autoNameRefreshGeneration += 1

        guard spaceSwitcher.isAccessibilityTrusted else {
            return
        }

        scheduleAutomaticNameRefreshAttempt(
            at: 0,
            generation: autoNameRefreshGeneration
        )
    }

    private func scheduleAutomaticNameRefreshAttempt(at attemptIndex: Int, generation: Int) {
        guard Constants.autoNameRefreshDelays.indices.contains(attemptIndex) else {
            return
        }

        let delay = Constants.autoNameRefreshDelays[attemptIndex]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.autoNameRefreshGeneration == generation else {
                return
            }

            switch self.refreshAutomaticNameForCurrentSpace() {
            case .updated:
                self.rebuildMenu()
            case .retryNeeded:
                self.scheduleAutomaticNameRefreshAttempt(
                    at: attemptIndex + 1,
                    generation: generation
                )
            case .unchanged:
                break
            }
        }
    }

    private func refreshAutomaticNameForCurrentSpace() -> AutomaticNameRefreshResult {
        guard let snapshot = spaceSwitcher.cursorSnapshot() ?? spaceSwitcher.menubarSnapshot(),
              let currentSpace = snapshot.currentSpace else {
            return .retryNeeded
        }

        switch fullScreenSpaceNameDetector.detectCurrentFullScreenAppName() {
        case .fullScreenApp(let name):
            let didChange = titleResolver.setAutomaticAlias(name, for: currentSpace.identity)
            return didChange ? .updated : .unchanged
        case .notFullScreen:
            let didChange = titleResolver.setAutomaticAlias(nil, for: currentSpace.identity)
            return didChange ? .updated : .unchanged
        case .unavailable:
            return .retryNeeded
        }
    }

    @objc private func handleActiveSpaceDidChange() {
        rebuildMenu()
        scheduleAutomaticNameRefresh()
    }

    @objc private func handleApplicationDidBecomeActive() {
        rebuildMenu()
    }

    @objc private func handleScreenParametersDidChange() {
        rebuildMenu()
    }

    @objc private func refresh() {
        rebuildMenu()
        scheduleAutomaticNameRefresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func currentScreenIndex() -> Int {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.firstIndex(where: { $0.frame.contains(mouseLocation) }) ?? 0
    }
}

private enum AutomaticNameRefreshResult {
    case updated
    case unchanged
    case retryNeeded
}

private final class HotkeyRecorderView: NSView {
    private enum Layout {
        static let width: CGFloat = 320
        static let height: CGFloat = 76
        static let cornerRadius: CGFloat = 8
    }

    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    private(set) var hotkey: SpaceHotkey?

    init(currentHotkey: SpaceHotkey?) {
        hotkey = currentHotkey
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height))

        configureView()
        configureLabels()
        updateLabels()
        updateFocusState(isFocused: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        updateFocusState(isFocused: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        updateFocusState(isFocused: false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let capturedHotkey = SpaceHotkey.from(event: event) else {
            NSSound.beep()
            return
        }

        hotkey = capturedHotkey
        updateLabels()
    }

    private func configureView() {
        wantsLayer = true
        layer?.cornerRadius = Layout.cornerRadius
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
    }

    private func configureLabels() {
        valueLabel.alignment = .center
        valueLabel.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(valueLabel)
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 8)
        ])
    }

    private func updateLabels() {
        valueLabel.stringValue = hotkey?.displayString ?? "Press Shortcut"
        detailLabel.stringValue = hotkey == nil
            ? "Modifier + key"
            : "Save to assign this hotkey"
    }

    private func updateFocusState(isFocused: Bool) {
        layer?.borderColor = (isFocused ? NSColor.controlAccentColor : .separatorColor).cgColor
    }
}

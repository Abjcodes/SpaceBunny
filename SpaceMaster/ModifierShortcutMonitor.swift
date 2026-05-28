import AppKit

@MainActor
final class ModifierShortcutMonitor {
    private let activationHandler: () -> Void
    private let commitHandler: () -> Void
    private let cancelHandler: () -> Void

    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var isShortcutActive = false

    init(
        activationHandler: @escaping () -> Void,
        commitHandler: @escaping () -> Void,
        cancelHandler: @escaping () -> Void
    ) {
        self.activationHandler = activationHandler
        self.commitHandler = commitHandler
        self.cancelHandler = cancelHandler
        start()
    }

    private func start() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleKeyDown()
            }
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown()
            return event
        }
    }

    private func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
        }

        flagsMonitor = nil
        localFlagsMonitor = nil
        keyDownMonitor = nil
        localKeyDownMonitor = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isHoldingShortcut = modifiers.contains(.command) && modifiers.contains(.shift)

        switch (isShortcutActive, isHoldingShortcut) {
        case (false, true):
            isShortcutActive = true
            activationHandler()
        case (true, false):
            isShortcutActive = false
            commitHandler()
        default:
            break
        }
    }

    private func handleKeyDown() {
        guard isShortcutActive else { return }
        isShortcutActive = false
        cancelHandler()
    }
}

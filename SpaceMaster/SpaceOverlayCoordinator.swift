import AppKit

@MainActor
final class SpaceOverlayCoordinator {
    private let overlayController: SpaceOverlayController
    private let shortcutMonitor: ModifierShortcutMonitor

    init(
        spaceSwitcher: SpaceSwitching,
        titleResolver: SpaceTitleResolver
    ) {
        let overlayController = SpaceOverlayController(
            spaceSwitcher: spaceSwitcher,
            titleResolver: titleResolver
        )
        self.overlayController = overlayController
        shortcutMonitor = ModifierShortcutMonitor(
            activationHandler: { [weak overlayController] in
                overlayController?.presentIfPossible()
            },
            commitHandler: { [weak overlayController] in
                overlayController?.commitSelectionAndDismiss()
            },
            cancelHandler: { [weak overlayController] in
                overlayController?.dismissWithoutSwitch()
            }
        )
    }
}

import Foundation

@MainActor
final class FourFingerInstantSwipeController {
    private enum Constants {
        static let enabledDefaultsKey = "fourFingerInstantSwipeEnabled"
        static let suppressionGraceInterval: TimeInterval = 0.35
    }

    private let spaceSwitcher: SpaceSwitching
    private let defaults: UserDefaults
    private let monitor = SwipeGestureMonitor()
    private let suppressor = SystemSwipeSuppressor()

    private var isMonitoring = false
    private var activeFingerCount = 0
    private var suppressNativeSwipeUntil: Date?

    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Constants.enabledDefaultsKey) != nil else {
                return true
            }

            return defaults.bool(forKey: Constants.enabledDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: Constants.enabledDefaultsKey)
            refresh()
        }
    }

    init(spaceSwitcher: SpaceSwitching, defaults: UserDefaults = .standard) {
        self.spaceSwitcher = spaceSwitcher
        self.defaults = defaults
        monitor.flipSwipeDirection = true

        monitor.onActiveFingerCountChanged = { [weak self] fingerCount in
            self?.handleActiveFingerCountChanged(fingerCount)
        }

        monitor.onSwipe = { [weak self] direction, fingerCount in
            self?.handleSwipe(direction: direction, fingerCount: fingerCount)
        }

        suppressor.shouldSuppressSwipe = { [weak self] in
            self?.shouldSuppressNativeSwipe() ?? false
        }

        refresh()
    }

    func toggleEnabled() {
        isEnabled.toggle()
    }

    func refresh() {
        guard isEnabled, spaceSwitcher.isAccessibilityTrusted else {
            stopMonitoring()
            return
        }

        guard !isMonitoring else { return }

        monitor.startMonitoring()
        suppressor.startMonitoring()
        isMonitoring = true
    }

    func stop() {
        stopMonitoring()
    }

    private func stopMonitoring() {
        monitor.stopMonitoring()
        suppressor.stopMonitoring()
        isMonitoring = false
        activeFingerCount = 0
        suppressNativeSwipeUntil = nil
    }

    private func handleActiveFingerCountChanged(_ fingerCount: Int) {
        activeFingerCount = fingerCount

        if fingerCount == 4 {
            armNativeSwipeSuppression()
        }
    }

    private func handleSwipe(direction: SwipeDirection, fingerCount: Int) {
        guard isEnabled, fingerCount == 4 else { return }

        armNativeSwipeSuppression()

        switch direction {
        case .left:
            _ = spaceSwitcher.switchToPreviousSpace()
        case .right:
            _ = spaceSwitcher.switchToNextSpace()
        }
    }

    private func shouldSuppressNativeSwipe() -> Bool {
        guard isEnabled, isMonitoring else { return false }

        if activeFingerCount == 4 {
            return true
        }

        guard let suppressNativeSwipeUntil else {
            return false
        }

        return Date() <= suppressNativeSwipeUntil
    }

    private func armNativeSwipeSuppression() {
        suppressNativeSwipeUntil = Date().addingTimeInterval(Constants.suppressionGraceInterval)
    }
}

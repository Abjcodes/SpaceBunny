import AppKit
import CoreGraphics
import Foundation

let kSyntheticMarkerField = CGEventField(rawValue: 200)!
let kSyntheticMarkerValue: Int64 = 0x5353_5749_5045

private let kSwipeDeltaThreshold: Double = 0.06
private let kSwipeDeltaXDominance: Double = 1.35

enum SwipeDirection {
    case left
    case right

    var opposite: SwipeDirection {
        switch self {
        case .left:
            return .right
        case .right:
            return .left
        }
    }
}

@MainActor
final class SwipeGestureMonitor {
    var onSwipe: ((SwipeDirection, Int) -> Void)?
    var onActiveFingerCountChanged: ((Int) -> Void)?
    var flipSwipeDirection = false

    private var eventTap: EventTap?
    private var state = GestureState()
    private var lastPublishedFingerCount = 0

    private struct GestureState {
        var isActive = false
        var lastFiredDirection: SwipeDirection?
        var accumulatedDeltaX: Double = 0
        var accumulatedDeltaY: Double = 0
        var previousPositions: [String: CGPoint] = [:]

        mutating func reset() {
            isActive = false
            lastFiredDirection = nil
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            previousPositions = [:]
        }
    }

    func startMonitoring() {
        guard eventTap == nil else { return }

        let tap = EventTap(
            label: "SwipeGestureMonitor",
            options: .defaultTap,
            location: .hidEventTap,
            place: .headInsertEventTap,
            types: [.gesture],
            callback: { [weak self] proxy, type, cgEvent in
                guard let self else { return cgEvent }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.resetState()
                    proxy.enable()
                    return cgEvent

                case .gesture:
                    if let nsEvent = NSEvent(cgEvent: cgEvent) {
                        self.handleEvent(nsEvent)
                    }
                    return cgEvent

                default:
                    return cgEvent
                }
            }
        )

        tap.enable()
        eventTap = tap
    }

    func stopMonitoring() {
        eventTap?.disable()
        eventTap = nil
        resetState()
    }

    private func handleEvent(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }

        if cgEvent.getIntegerValueField(kSyntheticMarkerField) == kSyntheticMarkerValue {
            return
        }

        let touches = event.allTouches()
        guard !touches.isEmpty else {
            resetState()
            return
        }

        let activeFingerCount =
            touches.allSatisfy { $0.phase == .ended || $0.phase == .cancelled } ? 0 : touches.count

        guard activeFingerCount > 0 else {
            resetState()
            return
        }

        publishActiveFingerCount(activeFingerCount)

        if !state.isActive {
            state.isActive = true
        }

        var dx: CGFloat = 0
        var dy: CGFloat = 0

        for touch in touches {
            let key = String(describing: touch.identity)
            let current = touch.normalizedPosition

            if let previous = state.previousPositions[key] {
                dx += current.x - previous.x
                dy += current.y - previous.y
            }

            if touch.phase == .ended || touch.phase == .cancelled {
                state.previousPositions.removeValue(forKey: key)
            } else {
                state.previousPositions[key] = current
            }
        }

        state.accumulatedDeltaX += dx
        state.accumulatedDeltaY += dy

        guard
            abs(state.accumulatedDeltaX) > abs(state.accumulatedDeltaY) * kSwipeDeltaXDominance,
            abs(state.accumulatedDeltaX) >= kSwipeDeltaThreshold
        else {
            return
        }

        let rawDirection: SwipeDirection = state.accumulatedDeltaX > 0 ? .right : .left
        let direction = flipSwipeDirection ? rawDirection.opposite : rawDirection
        guard direction != state.lastFiredDirection else {
            state.accumulatedDeltaX = 0
            return
        }

        state.lastFiredDirection = direction
        state.accumulatedDeltaX = 0

        let onSwipe = onSwipe
        DispatchQueue.main.async {
            onSwipe?(direction, activeFingerCount)
        }
    }

    private func resetState() {
        state.reset()
        publishActiveFingerCount(0)
    }

    private func publishActiveFingerCount(_ fingerCount: Int) {
        guard fingerCount != lastPublishedFingerCount else { return }
        lastPublishedFingerCount = fingerCount
        onActiveFingerCountChanged?(fingerCount)
    }
}

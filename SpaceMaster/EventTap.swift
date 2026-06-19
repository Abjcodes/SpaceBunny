@preconcurrency import CoreGraphics
import Foundation

@MainActor
final class EventTap {
    enum Location {
        case hidEventTap
        case sessionEventTap
        case annotatedSessionEventTap
        case pid(pid_t)
    }

    @MainActor
    struct Proxy {
        private let tap: EventTap
        private let pointer: CGEventTapProxy

        fileprivate init(tap: EventTap, pointer: CGEventTapProxy) {
            self.tap = tap
            self.pointer = pointer
        }

        func postEvent(_ event: CGEvent) {
            event.tapPostEvent(pointer)
        }

        func enable() {
            tap.enable()
        }

        func disable() {
            tap.disable()
        }
    }

    private let runLoop = CFRunLoopGetMain()
    private let mode: CFRunLoopMode = .commonModes
    private let callback: @MainActor (Proxy, CGEventType, CGEvent) -> CGEvent?

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?
    fileprivate nonisolated(unsafe) var tapMachPort: CFMachPort?

    let label: String

    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    init(
        label: String = #function,
        options: CGEventTapOptions,
        location: Location,
        place: CGEventTapPlacement,
        types: [CGEventType],
        callback: @MainActor @escaping (Proxy, CGEventType, CGEvent) -> CGEvent?
    ) {
        self.label = label
        self.callback = callback

        guard
            let machPort = Self.createTapMachPort(
                location: location,
                place: place,
                options: options,
                eventsOfInterest: types.reduce(into: 0) { $0 |= 1 << $1.rawValue },
                callback: handleEventTapEvent,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ),
            let source = CFMachPortCreateRunLoopSource(nil, machPort, 0)
        else {
            return
        }

        self.machPort = machPort
        self.tapMachPort = machPort
        self.source = source
    }

    deinit {
        guard let machPort else { return }
        CFRunLoopRemoveSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFMachPortInvalidate(machPort)
    }

    func enable() {
        guard let source, let machPort else { return }
        CFRunLoopAddSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func disable() {
        guard let source, let machPort else { return }
        CFRunLoopRemoveSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: false)
    }

    fileprivate func performCallback(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        callback(Proxy(tap: self, pointer: proxy), type, event)
            .map(Unmanaged.passUnretained)
    }

    private static func createTapMachPort(
        location: Location,
        place: CGEventTapPlacement,
        options: CGEventTapOptions,
        eventsOfInterest: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        if case .pid(let pid) = location {
            return CGEvent.tapCreateForPid(
                pid: pid,
                place: place,
                options: options,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
        }

        let tapLocation: CGEventTapLocation? =
            switch location {
            case .hidEventTap: .cghidEventTap
            case .sessionEventTap: .cgSessionEventTap
            case .annotatedSessionEventTap: .cgAnnotatedSessionEventTap
            case .pid: nil
            }

        guard let tapLocation else { return nil }

        return CGEvent.tapCreate(
            tap: tapLocation,
            place: place,
            options: options,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: userInfo
        )
    }
}

private nonisolated func handleEventTapEvent(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let eventTap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
       let machPort = eventTap.tapMachPort {
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    let payload = EventTapCallbackPayload(proxy: proxy, type: type, event: event)

    return MainActor.assumeIsolated {
        eventTap.performCallback(
            proxy: payload.proxy,
            type: payload.type,
            event: payload.event
        )
    }
}

private struct EventTapCallbackPayload: @unchecked Sendable {
    let proxy: CGEventTapProxy
    let type: CGEventType
    let event: CGEvent
}

extension CGEventType {
    static let gesture = CGEventType(rawValue: 29)!
}

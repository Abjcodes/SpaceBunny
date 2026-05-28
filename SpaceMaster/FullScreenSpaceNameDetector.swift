import AppKit
import ApplicationServices

@MainActor
final class FullScreenSpaceNameDetector {
    enum DetectionResult: Equatable {
        case fullScreenApp(String)
        case notFullScreen
        case unavailable
    }

    private let fullScreenAttribute = "AXFullScreen" as CFString

    func detectCurrentFullScreenAppName() -> DetectionResult {
        guard AXIsProcessTrusted() else {
            return .unavailable
        }

        guard let application = targetApplication(),
              let applicationName = application.localizedName,
              !applicationName.isEmpty else {
            return .unavailable
        }

        let axApplication = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = copyWindow(attribute: kAXFocusedWindowAttribute as CFString, from: axApplication)
            ?? copyWindow(attribute: kAXMainWindowAttribute as CFString, from: axApplication) else {
            return .unavailable
        }

        guard let isFullScreen = copyBoolAttribute(fullScreenAttribute, from: window) else {
            return .unavailable
        }

        return isFullScreen ? .fullScreenApp(applicationName) : .notFullScreen
    }

    private func targetApplication() -> NSRunningApplication? {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let workspace = NSWorkspace.shared
        let candidates = [workspace.menuBarOwningApplication, workspace.frontmostApplication]

        for application in candidates.compactMap({ $0 }) {
            if application.bundleIdentifier == bundleIdentifier {
                continue
            }

            return application
        }

        return nil
    }

    private func copyWindow(attribute: CFString, from application: AXUIElement) -> AXUIElement? {
        guard let value = copyAttributeValue(attribute, from: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> Bool? {
        guard let value = copyAttributeValue(attribute, from: element) else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        guard CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }

        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private func copyAttributeValue(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }

        return value
    }
}

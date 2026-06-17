import AppKit
import Carbon
import Foundation

struct SpaceHotkey: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let displayString: String

    static func == (lhs: SpaceHotkey, rhs: SpaceHotkey) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    static func from(event: NSEvent) -> SpaceHotkey? {
        let modifiers = event.modifierFlags.hotkeyCarbonModifiers
        guard modifiers != 0, let keyDisplayString = keyDisplayString(for: event) else {
            return nil
        }

        return SpaceHotkey(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            displayString: modifierDisplayString(for: modifiers) + keyDisplayString
        )
    }

    private static func modifierDisplayString(for modifiers: UInt32) -> String {
        var displayString = ""

        if modifiers & UInt32(controlKey) != 0 {
            displayString += "⌃"
        }
        if modifiers & UInt32(optionKey) != 0 {
            displayString += "⌥"
        }
        if modifiers & UInt32(shiftKey) != 0 {
            displayString += "⇧"
        }
        if modifiers & UInt32(cmdKey) != 0 {
            displayString += "⌘"
        }

        return displayString
    }

    private static func keyDisplayString(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Escape:
            return "Esc"
        case kVK_Delete:
            return "Delete"
        case kVK_ForwardDelete:
            return "Forward Delete"
        case kVK_Home:
            return "Home"
        case kVK_End:
            return "End"
        case kVK_PageUp:
            return "Page Up"
        case kVK_PageDown:
            return "Page Down"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        case kVK_F1:
            return "F1"
        case kVK_F2:
            return "F2"
        case kVK_F3:
            return "F3"
        case kVK_F4:
            return "F4"
        case kVK_F5:
            return "F5"
        case kVK_F6:
            return "F6"
        case kVK_F7:
            return "F7"
        case kVK_F8:
            return "F8"
        case kVK_F9:
            return "F9"
        case kVK_F10:
            return "F10"
        case kVK_F11:
            return "F11"
        case kVK_F12:
            return "F12"
        case kVK_F13:
            return "F13"
        case kVK_F14:
            return "F14"
        case kVK_F15:
            return "F15"
        case kVK_F16:
            return "F16"
        case kVK_F17:
            return "F17"
        case kVK_F18:
            return "F18"
        case kVK_F19:
            return "F19"
        case kVK_F20:
            return "F20"
        default:
            guard let characters = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !characters.isEmpty else {
                return nil
            }

            return characters.uppercased()
        }
    }
}

enum SpaceHotkeyAssignmentError: Error {
    case duplicate(existingStableStorageKey: String)
}

struct SpaceHotkeyRegistrationFailure {
    let stableStorageKey: String
    let hotkey: SpaceHotkey
    let status: OSStatus
}

final class SpaceHotkeyStore {
    private enum Constants {
        static let assignments = "spaceHotkeysByStableID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hotkey(for identity: MenubarSpaceIdentity?) -> SpaceHotkey? {
        guard let key = identity?.stableStorageKey else { return nil }
        return assignments()[key]
    }

    func setHotkey(
        _ hotkey: SpaceHotkey,
        for identity: MenubarSpaceIdentity
    ) throws {
        let key = identity.stableStorageKey
        var values = assignments()

        if let duplicate = values.first(where: { $0.key != key && $0.value == hotkey }) {
            throw SpaceHotkeyAssignmentError.duplicate(existingStableStorageKey: duplicate.key)
        }

        values[key] = hotkey
        save(values)
    }

    func clearHotkey(for identity: MenubarSpaceIdentity) {
        var values = assignments()
        values.removeValue(forKey: identity.stableStorageKey)
        save(values)
    }

    func allAssignments() -> [(stableStorageKey: String, hotkey: SpaceHotkey)] {
        assignments()
            .map { (stableStorageKey: $0.key, hotkey: $0.value) }
            .sorted { $0.stableStorageKey < $1.stableStorageKey }
    }

    private func assignments() -> [String: SpaceHotkey] {
        guard let data = defaults.data(forKey: Constants.assignments),
              let values = try? JSONDecoder().decode([String: SpaceHotkey].self, from: data) else {
            return [:]
        }

        return values
    }

    private func save(_ values: [String: SpaceHotkey]) {
        if values.isEmpty {
            defaults.removeObject(forKey: Constants.assignments)
            return
        }

        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Constants.assignments)
    }
}

final class SpaceHotkeyRegistrar {
    private let store: SpaceHotkeyStore
    private let spaceSwitcher: SpaceSwitching
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var stableKeysByID: [UInt32: String] = [:]
    private var eventHandler: EventHandlerRef?

    init(store: SpaceHotkeyStore, spaceSwitcher: SpaceSwitching) {
        self.store = store
        self.spaceSwitcher = spaceSwitcher
        installEventHandler()
    }

    deinit {
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    @MainActor
    @discardableResult
    func refresh() -> [SpaceHotkeyRegistrationFailure] {
        unregisterAll()

        var failures: [SpaceHotkeyRegistrationFailure] = []

        for (offset, assignment) in store.allAssignments().enumerated() {
            let hotkeyID = UInt32(offset + 1)
            let eventHotkeyID = EventHotKeyID(
                signature: SpaceHotkeyRegistrar.signature,
                id: hotkeyID
            )
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                assignment.hotkey.keyCode,
                assignment.hotkey.modifiers,
                eventHotkeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr, let ref {
                hotkeyRefs.append(ref)
                stableKeysByID[hotkeyID] = assignment.stableStorageKey
            } else {
                failures.append(
                    SpaceHotkeyRegistrationFailure(
                        stableStorageKey: assignment.stableStorageKey,
                        hotkey: assignment.hotkey,
                        status: status
                    )
                )
            }
        }

        return failures
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )

                guard status == noErr else { return noErr }

                let registrarPointer = UInt(bitPattern: userData)
                let pressedHotkeyID = hotkeyID.id

                Task { @MainActor in
                    guard let pointer = UnsafeRawPointer(bitPattern: registrarPointer) else {
                        return
                    }

                    let registrar = Unmanaged<SpaceHotkeyRegistrar>
                        .fromOpaque(pointer)
                        .takeUnretainedValue()
                    registrar.handleHotkey(id: pressedHotkeyID)
                }

                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )
    }

    @MainActor
    private func handleHotkey(id: UInt32) {
        guard let stableStorageKey = stableKeysByID[id],
              let snapshot = spaceSwitcher.cursorSnapshot() ?? spaceSwitcher.menubarSnapshot(),
              let index = snapshot.spaces.firstIndex(where: {
                  $0.identity.stableStorageKey == stableStorageKey
              }) else {
            return
        }

        _ = spaceSwitcher.switchToSpace(index + 1, onScreen: 0)
    }

    @MainActor
    private func unregisterAll() {
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        hotkeyRefs.removeAll()
        stableKeysByID.removeAll()
    }

    private static let signature: OSType = {
        let chars = Array("SMHK".utf8)
        return chars.reduce(0) { ($0 << 8) + OSType($1) }
    }()
}

private extension NSEvent.ModifierFlags {
    var hotkeyCarbonModifiers: UInt32 {
        let modifiers = intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0

        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }

        return carbonModifiers
    }
}

extension SpaceHotkey {
    var menuModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []

        if modifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if modifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if modifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }
        if modifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }

        return flags
    }

    var menuKeyEquivalent: String? {
        guard let key = displayKeyString else { return nil }

        switch key {
        case "Space":
            return " "
        case "Return":
            return "\r"
        case "Tab":
            return "\t"
        case "Esc":
            return "\u{1b}"
        case "Delete":
            return "\u{7f}"
        case "Forward Delete":
            return functionKeyEquivalent(0xF728)
        case "Home":
            return functionKeyEquivalent(0xF729)
        case "End":
            return functionKeyEquivalent(0xF72B)
        case "Page Up":
            return functionKeyEquivalent(0xF72C)
        case "Page Down":
            return functionKeyEquivalent(0xF72D)
        case "←":
            return functionKeyEquivalent(0xF702)
        case "→":
            return functionKeyEquivalent(0xF703)
        case "↑":
            return functionKeyEquivalent(0xF700)
        case "↓":
            return functionKeyEquivalent(0xF701)
        default:
            if let functionKeyNumber = functionKeyNumber(from: key) {
                return functionKeyEquivalent(0xF704 + functionKeyNumber - 1)
            }

            guard key.count == 1 else { return nil }
            return key.lowercased()
        }
    }

    private var displayKeyString: String? {
        let modifierGlyphs = ["⌃", "⌥", "⇧", "⌘"]
        let key = modifierGlyphs
            .reduce(displayString) { partialResult, glyph in
                partialResult.replacingOccurrences(of: glyph, with: "")
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return key.isEmpty ? nil : key
    }

    private func functionKeyNumber(from key: String) -> Int? {
        guard key.hasPrefix("F"),
              let number = Int(key.dropFirst()),
              (1...20).contains(number) else {
            return nil
        }

        return number
    }

    private func functionKeyEquivalent(_ codePoint: Int) -> String {
        guard let scalar = UnicodeScalar(codePoint) else { return "" }
        return String(Character(scalar))
    }
}

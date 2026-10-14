import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon flags (cmdKey, shiftKey, …)
    var label: String
}

enum HotKeyAction: UInt32, CaseIterable {
    case screenshot = 1, record = 2

    var title: String { self == .screenshot ? "Screenshot" : "Screen Record" }
    var defaultsKey: String { "hotkey.\(rawValue)" }
    var defaultShortcut: Shortcut {
        self == .screenshot
            ? Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘1")
            : Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘2")
    }
}

/// Global hotkeys via Carbon: works without Accessibility permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    var onFire: (HotKeyAction) -> Void = { _ in }
    var onChange: () -> Void = {}
    private var refs: [HotKeyAction: EventHotKeyRef] = [:]

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = HotKeyAction(rawValue: id.id) {
                Task { @MainActor in HotKeys.shared.onFire(action) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func shortcut(for action: HotKeyAction) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data) else { return action.defaultShortcut }
        return saved
    }

    /// Saves and registers; returns an error message if the combo is taken.
    func set(_ shortcut: Shortcut, for action: HotKeyAction) -> String? {
        if HotKeyAction.allCases.contains(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            return "\(shortcut.label) sudah dipakai untuk aksi lain."
        }
        let previous = self.shortcut(for: action)
        unregister(action)
        guard register(shortcut, for: action) else {
            _ = register(previous, for: action)
            return "\(shortcut.label) sudah dipakai app lain atau sistem."
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: action.defaultsKey)
        onChange()
        return nil
    }

    func registerAll() {
        for action in HotKeyAction.allCases { _ = register(shortcut(for: action), for: action) }
    }

    func unregisterAll() {
        HotKeyAction.allCases.forEach(unregister)
    }

    private func register(_ shortcut: Shortcut, for action: HotKeyAction) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5353_4854), id: action.rawValue)
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return false }
        refs[action] = ref
        return true
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }
}

/// Button that records the next key combo pressed while it is active.
@MainActor
final class ShortcutRecorder: NSButton {
    private let hotKeyAction: HotKeyAction
    private var monitor: Any?
    var onError: (String?) -> Void = { _ in }

    init(action: HotKeyAction) {
        hotKeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        self.action = #selector(startRecording)
        widthAnchor.constraint(equalToConstant: 140).isActive = true
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func refreshTitle() { title = HotKeys.shared.shortcut(for: hotKeyAction).label }

    @objc private func startRecording() {
        guard monitor == nil else { return }
        title = "Tekan kombinasi…"
        onError(nil)
        HotKeys.shared.unregisterAll() // otherwise the current combo fires instead of being recorded
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
    }

    func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        HotKeys.shared.registerAll()
        refreshTitle()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { return stopRecording() }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.subtracting(.shift).isEmpty else {
            onError("Pakai minimal satu dari ⌘ ⌥ ⌃.")
            return
        }
        var carbon: UInt32 = 0
        var label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        label += Self.keyName(event)
        let error = HotKeys.shared.set(Shortcut(keyCode: UInt32(event.keyCode), modifiers: carbon, label: label), for: hotKeyAction)
        stopRecording()
        onError(error)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = specialKeys[Int(event.keyCode)] { return name }
        let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars
    }
}

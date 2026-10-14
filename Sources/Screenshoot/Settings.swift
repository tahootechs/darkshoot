import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let drive = GoogleDrive.shared
    private let clientIDField = NSTextField()
    private let secretField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var signInButton = NSButton(title: "Sign in with Google", target: self, action: #selector(signIn))
    private lazy var signOutButton = NSButton(title: "Sign out", target: self, action: #selector(signOut))
    private var recorders: [ShortcutRecorder] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Screenshoot Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        clientIDField.placeholderString = "xxxx.apps.googleusercontent.com"
        secretField.placeholderString = "GOCSPX-…"
        for field in [clientIDField, secretField] {
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        let hint = NSTextField(wrappingLabelWithString:
            "Google Cloud Console → aktifkan Google Drive API → Credentials → OAuth client ID tipe \"Desktop app\".")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 320

        let hotkeyError = NSTextField(labelWithString: "")
        hotkeyError.font = .systemFont(ofSize: 11)
        hotkeyError.textColor = .systemRed
        var hotkeyRows: [[NSView]] = []
        for action in HotKeyAction.allCases {
            let recorder = ShortcutRecorder(action: action)
            recorder.onError = { hotkeyError.stringValue = $0 ?? "" }
            recorders.append(recorder)
            hotkeyRows.append([NSTextField(labelWithString: "\(action.title):"), recorder])
        }
        hotkeyRows.append([NSGridCell.emptyContentView, hotkeyError])
        let hotkeyGrid = NSGridView(views: hotkeyRows)
        hotkeyGrid.column(at: 0).xPlacement = .trailing
        hotkeyGrid.column(at: 0).width = 100
        hotkeyGrid.rowSpacing = 8

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Client ID:"), clientIDField],
            [NSTextField(labelWithString: "Client Secret:"), secretField],
            [NSGridCell.emptyContentView, hint],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.rowSpacing = 8

        let buttons = NSStackView(views: [signInButton, signOutButton, statusLabel])
        let content = NSStackView(views: [
            Self.header("Hotkey"), hotkeyGrid, Self.header("Google Drive"), grid, buttons,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = content
    }

    private static func header(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        clientIDField.stringValue = drive.clientID
        secretField.stringValue = drive.clientSecret
        refresh()
        recorders.forEach { $0.refreshTitle() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) {
        recorders.forEach { $0.stopRecording() }
        saveFields()
    }

    private func saveFields() {
        let id = clientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // A refresh token only works with the client that issued it.
        if id != drive.clientID { drive.signOut() }
        drive.clientID = id
        drive.clientSecret = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh() {
        statusLabel.stringValue = drive.isSignedIn ? "✓ Sudah login" : "Belum login"
        signInButton.isEnabled = true
        signOutButton.isEnabled = drive.isSignedIn
    }

    @objc private func signIn() {
        saveFields()
        signInButton.isEnabled = false
        statusLabel.stringValue = "Lanjutkan login di browser…"
        Task {
            do {
                try await drive.signIn()
                refresh()
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            } catch {
                refresh()
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func signOut() {
        drive.signOut()
        refresh()
    }
}

/// Small non-activating message at the top of the screen.
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, duration: TimeInterval = 3) {
        hide()
        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        let size = NSSize(width: min(label.fittingSize.width, 560), height: label.fittingSize.height)
        label.frame = NSRect(origin: NSPoint(x: 14, y: 10), size: size)

        let frame = NSRect(x: 0, y: 0, width: size.width + 28, height: size.height + 20)
        let background = NSView(frame: frame)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        background.layer?.cornerRadius = 10
        background.addSubview(label)

        let toast = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toast.level = .statusBar
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.ignoresMouseEvents = true
        toast.contentView = background
        if let screen = NSScreen.main?.visibleFrame {
            toast.setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.maxY - frame.height - 16))
        }
        toast.orderFrontRegardless()
        panel = toast

        Task {
            try? await Task.sleep(for: .seconds(duration))
            if panel === toast { hide() }
        }
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

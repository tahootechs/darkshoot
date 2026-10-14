import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let drive = GoogleDrive.shared
    private let clientIDField = NSTextField()
    private let secretField = NSSecureTextField()
    private let folderField = NSTextField()
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
        folderField.placeholderString = "Kosongkan untuk root My Drive"
        for field in [clientIDField, secretField, folderField] {
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
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
            [NSTextField(labelWithString: "Folder:"), folderField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 100
        grid.rowSpacing = 8

        let buttons = NSStackView(views: [signInButton, signOutButton, statusLabel])
        let content = NSStackView(views: [
            Self.header("Hotkey"), hotkeyGrid, Self.header("Google Drive"), grid, buttons,
            Self.header("Google Drive setup guide"), Self.setupGuideView(),
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

    /// Console links act on the project selected in the console's top bar.
    private static let setupGuide = """
        **1. Create a Google Cloud project**
        Open [Create project](https://console.cloud.google.com/projectcreate), enter any name, then click Create. \
        Make sure the new project is selected in the top bar before following the next links.

        **2. Enable the Google Drive API**
        Open [Google Drive API](https://console.cloud.google.com/apis/library/drive.googleapis.com) and click Enable.

        **3. Configure the consent screen**
        Open [Branding](https://console.cloud.google.com/auth/branding) and click Get started.
        • App name: Screenshoot, User support email: your email
        • Audience: External
        • Contact information: your email
        • Accept the policy, then click Create.

        **4. Create the OAuth client**
        Open [Create client](https://console.cloud.google.com/auth/clients/create).
        • Application type: Desktop app, Name: anything
        • Click Create, then copy the Client ID and Client Secret into the fields above. \
        In a downloaded JSON file they are "client_id" and "client_secret".

        **5. Allow your Google account to sign in (pick one)**
        Without this step, sign-in fails with "Error 403: access_denied".

        **Option 1: Add yourself as a test user (fastest)**
        • Open [Audience](https://console.cloud.google.com/auth/audience), go to Test users, click Add users.
        • Enter the exact Google account email you sign in with, then click Save.
        • While the app is in Testing, sign-in expires every 7 days. Click Sign in with Google again when it does.

        **Option 2: Publish the app (no weekly sign-in)**
        • Open [Audience](https://console.cloud.google.com/auth/audience), click Publish app, then Confirm.
        • When signing in, Google warns "Google hasn't verified this app". \
        Click Advanced → Go to Screenshoot (unsafe) → Continue. This is expected for your own OAuth client.

        **6. Sign in**
        Click Sign in with Google above and finish in the browser. The status changes to "✓ Sudah login".
        """

    private static func setupGuideView() -> NSScrollView {
        let parsed = try! NSAttributedString(markdown: setupGuide,
                                             options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let text = NSMutableAttributedString(attributedString: parsed)
        let all = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 3
        text.addAttributes([.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: paragraph], range: all)
        // Markdown parsing marks **bold** with an intent attribute that AppKit does not render on its own.
        text.enumerateAttribute(.inlinePresentationIntent, in: all) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue,
                  InlinePresentationIntent(rawValue: raw).contains(.stronglyEmphasized) else { return }
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: range)
        }

        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false // still selectable, so links open in the browser on click
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textStorage?.setAttributedString(text)
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
        return scroll
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        clientIDField.stringValue = drive.clientID
        secretField.stringValue = drive.clientSecret
        folderField.stringValue = drive.folderName
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
        drive.folderName = folderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

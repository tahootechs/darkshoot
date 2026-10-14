import AppKit
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let captureItem = NSMenuItem(title: "", action: #selector(captureFromMenu), keyEquivalent: "")
    private let recordItem = NSMenuItem(title: "", action: #selector(recordFromMenu), keyEquivalent: "")
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        captureItem.target = self
        recordItem.target = self
        menu.addItem(captureItem)
        menu.addItem(recordItem)
        let galleryItem = NSMenuItem(title: "Gallery…", action: #selector(openGallery), keyEquivalent: "")
        galleryItem.target = self
        menu.addItem(galleryItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Hidden in an accessory app, but routes ⌘X/⌘C/⌘V/⌘A to text fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)

        HotKeys.shared.onFire = { [weak self] action in
            action == .screenshot ? self?.capture(.image) : self?.toggleRecording()
        }
        HotKeys.shared.onChange = { [weak self] in self?.updateMenu() }
        ScreenRecorder.shared.onStateChange = { [weak self] in self?.updateMenu() }
        HotKeys.shared.registerAll()
        updateMenu()
    }

    private func updateMenu() {
        let recording = ScreenRecorder.shared.isRecording
        captureItem.title = "Screenshot (\(HotKeys.shared.shortcut(for: .screenshot).label))"
        recordItem.title = "\(recording ? "Stop Recording" : "Screen Record") (\(HotKeys.shared.shortcut(for: .record).label))"
        statusItem.button?.image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "camera.viewfinder",
                                           accessibilityDescription: "Screenshoot")
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    @objc private func captureFromMenu() { capture(.image) }
    @objc private func recordFromMenu() { toggleRecording() }
    @objc private func openGallery() { GalleryWindowController.shared.show() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }

    private func toggleRecording() {
        ScreenRecorder.shared.isRecording ? ScreenRecorder.shared.stop() : capture(.record)
    }

    func capture(_ mode: CaptureMode) {
        guard !capturing, CaptureSession.current == nil, !ScreenRecorder.shared.isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showAlert("Izinkan Screen Recording untuk Screenshoot di System Settings → Privacy & Security, lalu buka ulang app.")
            return
        }
        capturing = true
        Task {
            defer { capturing = false }
            do {
                CaptureSession.current = CaptureSession(shots: try await captureScreens(), mode: mode)
            } catch {
                showAlert("Gagal mengambil screenshot: \(error.localizedDescription)")
            }
        }
    }

    /// Freezes every screen first, like Lightshot, so the user selects on a still image.
    private func captureScreens() async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            shots.append((screen, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)))
        }
        return shots
    }

    private func showAlert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

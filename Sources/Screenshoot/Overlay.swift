import AppKit
import UniformTypeIdentifiers

// MARK: - Session

enum CaptureMode { case image, record }

@MainActor
final class CaptureSession {
    static var current: CaptureSession?
    let mode: CaptureMode
    private var windows: [OverlayWindow] = []

    init(shots: [(NSScreen, CGImage)], mode: CaptureMode) {
        self.mode = mode
        for (screen, image) in shots {
            let window = OverlayWindow(frame: screen.frame)
            window.contentView = OverlayView(image: image, size: screen.frame.size, session: self)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        key?.makeFirstResponder(key?.contentView)
    }

    /// Only one screen holds a selection at a time.
    func beganSelection(in view: OverlayView) {
        for window in windows where window.contentView !== view {
            (window.contentView as? OverlayView)?.clearSelection()
        }
        view.window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        CaptureSession.current = nil
    }

    func startRecording(screen: NSScreen, rect: NSRect) {
        close()
        Task {
            do {
                try await ScreenRecorder.shared.start(screen: screen, rect: rect)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }
}

final class OverlayWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        level = .screenSaver
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Annotations

enum Tool: Int { case none, pen, line, arrow, rect, ellipse, marker, text }

struct Annotation {
    enum Kind { case pen, line, arrow, rect, ellipse, marker, text(String) }
    var kind: Kind
    var color: NSColor
    var points: [NSPoint]
    var width: CGFloat = 3

    static let textFont = NSFont.systemFont(ofSize: 18, weight: .semibold)

    func draw() {
        guard let first = points.first, let last = points.last else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = width
        color.set()
        switch kind {
        case .pen, .marker:
            path.move(to: first)
            points.dropFirst().forEach { path.line(to: $0) }
            if case .marker = kind {
                path.lineWidth = width * 4
                color.withAlphaComponent(0.4).set()
            }
            path.stroke()
        case .line:
            path.move(to: first)
            path.line(to: last)
            path.stroke()
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let headLength = 10 + width * 3
            // End the round-capped shaft inside the head so it never pokes past the tip.
            path.move(to: first)
            path.line(to: NSPoint(x: last.x - headLength / 2 * cos(angle), y: last.y - headLength / 2 * sin(angle)))
            path.stroke()
            let head = NSBezierPath()
            head.move(to: last)
            for side in [CGFloat.pi / 7, -CGFloat.pi / 7] {
                head.line(to: NSPoint(x: last.x - headLength * cos(angle + side), y: last.y - headLength * sin(angle + side)))
            }
            head.close()
            head.fill()
        case .rect, .ellipse:
            let box = NSRect(x: min(first.x, last.x), y: min(first.y, last.y),
                             width: abs(last.x - first.x), height: abs(last.y - first.y))
            if case .rect = kind { path.appendRect(box) } else { path.appendOval(in: box) }
            path.stroke()
        case .text(let string):
            (string as NSString).draw(at: first, withAttributes: [.font: Self.textFont, .foregroundColor: color])
        }
    }
}

// MARK: - Overlay view

@MainActor
final class OverlayView: NSView, NSTextFieldDelegate {
    private let cgImage: CGImage
    private let image: NSImage
    private weak var session: CaptureSession?
    private let mode: CaptureMode

    private var selection: NSRect?
    private var dragStart: NSPoint?
    private var annotations: [Annotation] = []
    private var current: Annotation?
    private var tool = Tool.none
    private var color = NSColor.systemRed
    private var width: CGFloat = 4
    private var textField: NSTextField?

    private static let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .white]
    private static let widths: [CGFloat] = [2, 4, 8]
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var widthButtons: [NSButton] = []
    private lazy var toolbar = makeToolbar()

    init(image: CGImage, size: NSSize, session: CaptureSession) {
        cgImage = image
        self.image = NSImage(cgImage: image, size: size)
        self.session = session
        mode = session.mode
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func clearSelection() {
        commitText()
        selection = nil
        annotations.removeAll()
        toolbar.isHidden = true
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)

        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.appendRect(selection)
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        guard let selection else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.setLineDash([4, 4], count: 2, phase: 0)
        border.stroke()
        drawSizeLabel(for: selection)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        annotations.forEach { $0.draw() }
        current?.draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSizeLabel(for rect: NSRect) {
        let scale = pixelScale
        let text = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 4)
        if origin.y + size.height + 4 > bounds.maxY { origin.y = rect.maxY - size.height - 6 }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(origin: origin, size: size).insetBy(dx: -4, dy: -2), xRadius: 3, yRadius: 3).fill()
        text.draw(at: origin, withAttributes: attrs)
    }

    private var pixelScale: CGFloat { CGFloat(cgImage.width) / bounds.width }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        commitText()

        if let selection, tool != .none {
            guard selection.contains(point) else { return }
            if tool == .text {
                beginText(at: point)
            } else {
                current = Annotation(kind: annotationKind(for: tool), color: color, points: [point], width: width)
            }
            return
        }

        session?.beganSelection(in: self)
        annotations.removeAll()
        dragStart = point
        selection = NSRect(origin: point, size: .zero)
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let dragStart {
            selection = NSRect(x: min(dragStart.x, point.x), y: min(dragStart.y, point.y),
                               width: abs(point.x - dragStart.x), height: abs(point.y - dragStart.y))
                .intersection(bounds)
        } else if current != nil {
            switch current!.kind {
            case .pen, .marker: current!.points.append(point)
            default: current!.points = [current!.points[0], point]
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil {
            dragStart = nil
            if let selection, selection.width >= 4, selection.height >= 4 {
                showToolbar()
            } else {
                selection = nil
            }
        } else if let current {
            annotations.append(current)
            self.current = nil
        }
        needsDisplay = true
    }

    private func annotationKind(for tool: Tool) -> Annotation.Kind {
        switch tool {
        case .pen: .pen
        case .line: .line
        case .arrow: .arrow
        case .rect: .rect
        case .ellipse: .ellipse
        case .marker: .marker
        case .text, .none: .text("")
        }
    }

    // MARK: Text tool

    private func beginText(at point: NSPoint) {
        guard let selection else { return }
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 13, width: max(60, selection.maxX - point.x), height: 26))
        field.font = Annotation.textFont
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        // NSTextField insets its text by ~2pt from the frame edge.
        annotations.append(Annotation(kind: .text(text), color: field.textColor ?? color,
                                      points: [NSPoint(x: field.frame.minX + 2, y: field.frame.minY + 2)]))
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: session?.close()             // Esc
        case 36, 76:                          // Return / Enter
            mode == .record ? startRecording() : copyToClipboard()
        default:
            guard mode == .image, event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copyToClipboard()
            case "s": saveToFile()
            case "d": uploadToDrive()
            case "z": undo()
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: Toolbar

    private func makeToolbar() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        stack.layer?.cornerRadius = 8
        stack.isHidden = true
        addSubview(stack)

        if mode == .record {
            let record = iconButton("record.circle", "Start Recording (Enter)", #selector(startRecording))
            record.contentTintColor = .systemRed
            stack.addArrangedSubview(record)
            stack.addArrangedSubview(iconButton("xmark", "Close (Esc)", #selector(closeSession)))
            return stack
        }

        let tools: [(Tool, String, String)] = [
            (.pen, "pencil", "Pen"), (.line, "line.diagonal", "Line"), (.arrow, "arrow.up.right", "Arrow"),
            (.rect, "rectangle", "Rectangle"), (.ellipse, "circle", "Ellipse"), (.marker, "highlighter", "Marker"),
            (.text, "textformat", "Text"),
        ]
        for (tool, symbol, tip) in tools {
            let button = iconButton(symbol, tip, #selector(toolTapped(_:)))
            button.tag = tool.rawValue
            toolButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.setCustomSpacing(12, after: toolButtons.last!)

        for (index, swatch) in Self.colors.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(colorTapped(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = swatch.cgColor
            button.layer?.cornerRadius = 9
            button.layer?.borderColor = NSColor.systemGray.cgColor
            button.tag = index
            button.toolTip = "Color"
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.setCustomSpacing(12, after: colorButtons.last!)

        for (index, dot) in [6.0, 10.0, 14.0].enumerated() {
            let button = iconButton("circle.fill", "Stroke width", #selector(widthTapped(_:)))
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: dot, weight: .regular))
            button.tag = index
            widthButtons.append(button)
            stack.addArrangedSubview(button)
        }
        stack.setCustomSpacing(12, after: widthButtons.last!)

        stack.addArrangedSubview(iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undo)))
        stack.addArrangedSubview(iconButton("square.and.arrow.down", "Save (⌘S)", #selector(saveToFile)))
        stack.addArrangedSubview(iconButton("icloud.and.arrow.up", "Upload to Google Drive (⌘D)", #selector(uploadToDrive)))
        stack.addArrangedSubview(iconButton("doc.on.doc", "Copy (⌘C / Enter)", #selector(copyToClipboard)))
        stack.addArrangedSubview(iconButton("xmark", "Close (Esc)", #selector(closeSession)))

        updateToolbarState()
        return stack
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func showToolbar() {
        guard let selection else { return }
        let size = toolbar.fittingSize
        var y = selection.minY - size.height - 6
        if y < bounds.minY + 4 { y = selection.maxY + 6 }
        if y + size.height > bounds.maxY - 4 { y = selection.minY + 6 }
        let x = min(max(selection.maxX - size.width, bounds.minX + 4), bounds.maxX - size.width - 4)
        toolbar.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        toolbar.isHidden = false
    }

    private func updateToolbarState() {
        for button in toolButtons {
            button.contentTintColor = button.tag == tool.rawValue ? .controlAccentColor : .labelColor
        }
        for button in colorButtons {
            button.layer?.borderWidth = Self.colors[button.tag] == color ? 3 : 1
        }
        for button in widthButtons {
            button.contentTintColor = Self.widths[button.tag] == width ? .controlAccentColor : .labelColor
        }
    }

    @objc private func toolTapped(_ sender: NSButton) {
        commitText()
        let picked = Tool(rawValue: sender.tag) ?? .none
        tool = picked == tool ? .none : picked
        updateToolbarState()
        window?.makeFirstResponder(self)
    }

    @objc private func widthTapped(_ sender: NSButton) {
        width = Self.widths[sender.tag]
        updateToolbarState()
    }

    @objc private func colorTapped(_ sender: NSButton) {
        color = Self.colors[sender.tag]
        textField?.textColor = color
        updateToolbarState()
    }

    @objc private func undo() {
        commitText()
        if !annotations.isEmpty { annotations.removeLast() }
        needsDisplay = true
    }

    @objc private func closeSession() { session?.close() }

    // MARK: Export

    /// Crops the frozen screen image to the selection at full pixel resolution and burns in annotations.
    private func renderSelection() -> NSBitmapImageRep? {
        commitText()
        guard let selection else { return nil }
        let scale = pixelScale
        let pixelRect = NSRect(x: selection.minX * scale, y: (bounds.height - selection.maxY) * scale,
                               width: selection.width * scale, height: selection.height * scale).integral
        guard let cropped = cgImage.cropping(to: pixelRect),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cropped.width, pixelsHigh: cropped.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Must precede context creation: the context reads the point size to pick its scale.
        rep.size = selection.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSImage(cgImage: cropped, size: selection.size).draw(in: NSRect(origin: .zero, size: selection.size))
        let shift = NSAffineTransform()
        shift.translateX(by: -selection.minX, yBy: -selection.minY)
        shift.concat()
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Edit menu ⌘C lands here before keyDown.
    @objc func copy(_ sender: Any?) { if mode == .image { copyToClipboard() } }

    @objc private func startRecording() {
        guard let selection, let screen = window?.screen else { return }
        session?.startRecording(screen: screen, rect: selection)
    }

    @objc private func copyToClipboard() {
        guard let rep = renderSelection() else { return }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        session?.close()
    }

    @objc private func saveToFile() {
        guard let png = renderSelection()?.representation(using: .png, properties: [:]) else { return }
        session?.close()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = screenshotFileName()
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func uploadToDrive() {
        guard let png = renderSelection()?.representation(using: .png, properties: [:]) else { return }
        session?.close()
        GoogleDrive.shared.uploadAndCopyLink(png, name: screenshotFileName())
    }
}

func screenshotFileName() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "Screenshot \(formatter.string(from: Date())).png"
}

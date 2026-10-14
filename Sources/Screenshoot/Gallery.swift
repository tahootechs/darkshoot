import AppKit

/// Grid of the screenshots this app uploaded to Google Drive.
@MainActor
final class GalleryWindowController: NSWindowController, NSCollectionViewDataSource {
    static let shared = GalleryWindowController()

    private static let thumbnailPixels = 400

    private let drive = GoogleDrive.shared
    private let collectionView = NSCollectionView()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var refreshButton = NSButton(title: "Refresh", target: self, action: #selector(reload))
    private lazy var settingsButton = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
    private var files: [DriveFile] = []
    private var thumbnails: [String: NSImage] = [:]
    private var loadingThumbnails: Set<String> = []
    private var loadTask: Task<Void, Never>?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Screenshoot Gallery"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 200, height: 180)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(GalleryItem.self, forItemWithIdentifier: GalleryItem.identifier)

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        settingsButton.isHidden = true
        let bar = NSStackView(views: [refreshButton, settingsButton, statusLabel])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let content = NSView()
        for view in [bar, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        reload()
    }

    /// Called after an upload so an open gallery shows the new screenshot.
    func reloadIfVisible() {
        if window?.isVisible == true { reload() }
    }

    @objc private func reload() {
        loadTask?.cancel()
        guard drive.isSignedIn else {
            show(files: [])
            setStatus("Belum login ke Google Drive.", needsSettings: true)
            return
        }
        refreshButton.isEnabled = false
        setStatus("Memuat…")
        loadTask = Task {
            do {
                let files = try await drive.listUploads()
                guard !Task.isCancelled else { return }
                show(files: files)
                setStatus(files.isEmpty
                          ? "Belum ada screenshot yang diupload."
                          : "\(files.count) screenshot. Klik dua kali untuk membuka, klik kanan untuk copy link.")
            } catch {
                guard !Task.isCancelled else { return }
                setStatus(error.localizedDescription, needsSettings: !drive.isSignedIn)
            }
            refreshButton.isEnabled = true
        }
    }

    private func show(files: [DriveFile]) {
        self.files = files
        collectionView.reloadData()
    }

    private func setStatus(_ text: String, needsSettings: Bool = false) {
        statusLabel.stringValue = text
        settingsButton.isHidden = !needsSettings
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { files.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GalleryItem.identifier, for: indexPath) as! GalleryItem
        let file = files[indexPath.item]
        item.configure(file, image: thumbnails[file.id])
        if thumbnails[file.id] == nil { loadThumbnail(file) }
        return item
    }

    private func loadThumbnail(_ file: DriveFile) {
        guard loadingThumbnails.insert(file.id).inserted else { return }
        Task {
            let image = try? await drive.thumbnail(for: file, maxPixels: Self.thumbnailPixels)
            loadingThumbnails.remove(file.id)
            guard let image else { return }
            thumbnails[file.id] = image
            // Only visible items exist; others pick the image up from the cache when they scroll in.
            if let index = files.firstIndex(where: { $0.id == file.id }),
               let item = collectionView.item(at: index) as? GalleryItem, item.fileID == file.id {
                item.setImage(image)
            }
        }
    }
}

/// One tile: thumbnail, file name, upload date. Double-click opens it in the browser; right-click copies the link.
@MainActor
final class GalleryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryItem")

    private(set) var fileID: String?
    private var link: URL?
    private let thumbnail = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let cell = GalleryCellView()
        cell.onDoubleClick = { [weak self] in self?.openInBrowser() }
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 8
        cell.layer?.borderWidth = 2

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.contentTintColor = .tertiaryLabelColor
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        for view in [thumbnail, nameLabel, dateLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            thumbnail.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            thumbnail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            thumbnail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            thumbnail.heightAnchor.constraint(equalToConstant: 124),
            nameLabel.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor),
            dateLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            dateLabel.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor),
        ])

        let menu = NSMenu()
        menu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Link", action: #selector(copyLink), keyEquivalent: "").target = self
        cell.menu = menu
        view = cell
        updateSelection()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    func configure(_ file: DriveFile, image: NSImage?) {
        fileID = file.id
        link = URL(string: file.webViewLink)
        nameLabel.stringValue = file.name
        dateLabel.stringValue = file.createdTime.formatted(date: .abbreviated, time: .shortened)
        setImage(image)
    }

    func setImage(_ image: NSImage?) {
        thumbnail.image = image ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    }

    private func updateSelection() {
        view.layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
    }

    @objc private func openInBrowser() {
        if let link { NSWorkspace.shared.open(link) }
    }

    @objc private func copyLink() {
        guard let link else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        Toast.show("Link disalin: \(link.absoluteString)")
    }
}

private final class GalleryCellView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }
}

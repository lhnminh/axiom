import AppKit
import PDFKit
import UniformTypeIdentifiers

enum TextbookURLResolver {
    static func resolve(_ textbook: TextbookSummary) -> URL? {
        if let bookmark = textbook.bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let url = URL(fileURLWithPath: textbook.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

enum AxiomBrand {
    static let logo: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Axiom Logo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private enum LibraryPalette {
    static let canvas = NSColor(calibratedRed: 0.095, green: 0.098, blue: 0.106, alpha: 1)
    static let raised = NSColor(calibratedRed: 0.135, green: 0.139, blue: 0.149, alpha: 1)
    static let border = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let primaryText = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let secondaryText = NSColor(calibratedWhite: 0.66, alpha: 1)
}

@MainActor
private enum TextbookCoverCache {
    static let images = NSCache<NSString, NSImage>()

    static func image(for textbook: TextbookSummary) -> NSImage? {
        let key = textbook.fileFingerprint as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let url = TextbookURLResolver.resolve(textbook) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let image = PDFDocument(url: url)?.page(at: 0)?.thumbnail(
            of: NSSize(width: 360, height: 480),
            for: .cropBox
        ) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

@MainActor
final class TextbookCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("TextbookCardItem")

    private let cover = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let moreButton = NSButton()
    private var textbook: TextbookSummary?
    var onOpen: ((TextbookSummary) -> Void)?
    var onRetry: ((TextbookSummary) -> Void)?
    var onLocate: ((TextbookSummary) -> Void)?
    var onRemove: ((TextbookSummary) -> Void)?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        let coverSurface = NSView()
        coverSurface.wantsLayer = true
        coverSurface.layer?.backgroundColor = LibraryPalette.raised.cgColor
        coverSurface.layer?.cornerRadius = 8
        coverSurface.layer?.borderWidth = 1
        coverSurface.layer?.borderColor = LibraryPalette.border.cgColor
        coverSurface.translatesAutoresizingMaskIntoConstraints = false

        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 7
        cover.translatesAutoresizingMaskIntoConstraints = false
        coverSurface.addSubview(cover)

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = LibraryPalette.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = LibraryPalette.secondaryText
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlTint = .blueControlTint
        progress.translatesAutoresizingMaskIntoConstraints = false

        continueButton.target = self
        continueButton.action = #selector(openTextbook)
        continueButton.bezelStyle = .rounded
        continueButton.font = .systemFont(ofSize: 13, weight: .medium)
        continueButton.contentTintColor = LibraryPalette.primaryText
        continueButton.translatesAutoresizingMaskIntoConstraints = false

        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More textbook actions")
        moreButton.imagePosition = .imageOnly
        moreButton.isBordered = false
        moreButton.contentTintColor = LibraryPalette.secondaryText
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)
        moreButton.toolTip = "More actions"
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(coverSurface)
        root.addSubview(titleLabel)
        root.addSubview(detailLabel)
        root.addSubview(progress)
        root.addSubview(continueButton)
        root.addSubview(moreButton)
        NSLayoutConstraint.activate([
            coverSurface.topAnchor.constraint(equalTo: root.topAnchor),
            coverSurface.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            coverSurface.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.82),
            coverSurface.heightAnchor.constraint(equalTo: coverSurface.widthAnchor, multiplier: 1.20),
            cover.topAnchor.constraint(equalTo: coverSurface.topAnchor),
            cover.leadingAnchor.constraint(equalTo: coverSurface.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: coverSurface.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: coverSurface.bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: coverSurface.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            moreButton.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            moreButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 24),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 9),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            continueButton.topAnchor.constraint(greaterThanOrEqualTo: progress.bottomAnchor, constant: 10),
            continueButton.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            continueButton.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            continueButton.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            continueButton.heightAnchor.constraint(equalToConstant: 34)
        ])
        view = root
    }

    func configure(textbook: TextbookSummary) {
        self.textbook = textbook
        titleLabel.stringValue = textbook.displayName
        cover.image = TextbookCoverCache.image(for: textbook)
        cover.imageScaling = cover.image == nil ? .scaleNone : .scaleProportionallyUpOrDown
        if cover.image == nil {
            cover.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Textbook cover")
            cover.contentTintColor = LibraryPalette.secondaryText
        }

        switch textbook.extractionStatus {
        case "ready":
            detailLabel.stringValue = "\(textbook.pageCount) pages"
            progress.isHidden = true
        case "failed":
            detailLabel.stringValue = "Metadata needs attention"
            progress.isHidden = true
        default:
            detailLabel.stringValue = "\(textbook.extractedPages) of \(textbook.pageCount) pages"
            progress.isHidden = false
            progress.doubleValue = textbook.pageCount > 0
                ? Double(textbook.extractedPages) / Double(textbook.pageCount)
                : 0
        }
        continueButton.title = TextbookURLResolver.resolve(textbook) == nil ? "Locate PDF" : "Continue"
    }

    @objc private func openTextbook() {
        guard let textbook else { return }
        onOpen?(textbook)
    }

    @objc private func showMoreMenu() {
        guard let textbook else { return }
        let menu = NSMenu()
        if textbook.extractionStatus == "failed" {
            let retry = NSMenuItem(title: "Retry Metadata", action: #selector(retryMetadata), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        let locate = NSMenuItem(title: "Locate PDF…", action: #selector(locatePDF), keyEquivalent: "")
        locate.target = self
        menu.addItem(locate)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove from Library", action: #selector(removeFromLibrary), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.bounds.maxX, y: moreButton.bounds.minY), in: moreButton)
    }

    @objc private func retryMetadata() {
        guard let textbook else { return }
        onRetry?(textbook)
    }

    @objc private func locatePDF() {
        guard let textbook else { return }
        onLocate?(textbook)
    }

    @objc private func removeFromLibrary() {
        guard let textbook else { return }
        onRemove?(textbook)
    }
}

@MainActor
final class LibraryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSTextFieldDelegate {
    private let store: TextbookStore
    private let extractor: TextbookMetadataExtractor
    private let onOpen: (TextbookSummary) -> Void
    private let collectionView = NSCollectionView()
    private let collectionLayout = NSCollectionViewFlowLayout()
    private let searchField = NSTextField()
    private let recentLabel = NSTextField(labelWithString: "Recent")
    private let emptyLabel = NSTextField(labelWithString: "")
    private var textbooks: [TextbookSummary] = []
    private var filteredTextbooks: [TextbookSummary] = []
    private var refreshTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activeExtractions: Set<Int64> = []

    init(store: TextbookStore, extractor: TextbookMetadataExtractor, onOpen: @escaping (TextbookSummary) -> Void) {
        self.store = store
        self.extractor = extractor
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = LibraryPalette.canvas.cgColor
        root.appearance = NSAppearance(named: .darkAqua)

        let sidebar = makeSidebar()
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = LibraryPalette.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = LibraryPalette.canvas.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "What will you learn today?")
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        heading.textColor = LibraryPalette.primaryText
        heading.alignment = .center
        heading.translatesAutoresizingMaskIntoConstraints = false

        let searchSurface = NSView()
        searchSurface.wantsLayer = true
        searchSurface.layer?.backgroundColor = LibraryPalette.raised.cgColor
        searchSurface.layer?.borderWidth = 1
        searchSurface.layer?.borderColor = LibraryPalette.border.cgColor
        searchSurface.layer?.cornerRadius = 14
        searchSurface.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search your library"
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.textColor = LibraryPalette.primaryText
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage()
        )
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        searchIcon.contentTintColor = LibraryPalette.secondaryText
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton()
        addButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Add textbook folder")
        addButton.imagePosition = .imageOnly
        addButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        addButton.isBordered = false
        addButton.wantsLayer = true
        addButton.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        addButton.layer?.borderWidth = 1
        addButton.layer?.borderColor = LibraryPalette.border.cgColor
        addButton.layer?.cornerRadius = 8
        addButton.contentTintColor = LibraryPalette.primaryText
        addButton.target = self
        addButton.action = #selector(addFolder)
        addButton.toolTip = "Add a folder of textbook PDFs"
        addButton.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.addSubview(searchIcon)
        searchSurface.addSubview(searchField)
        searchSurface.addSubview(addButton)

        recentLabel.font = .systemFont(ofSize: 16, weight: .medium)
        recentLabel.textColor = LibraryPalette.primaryText
        recentLabel.translatesAutoresizingMaskIntoConstraints = false

        collectionLayout.minimumInteritemSpacing = 24
        collectionLayout.minimumLineSpacing = 32
        collectionLayout.sectionInset = NSEdgeInsets(top: 4, left: 0, bottom: 18, right: 0)
        collectionLayout.itemSize = NSSize(width: 220, height: 326)
        collectionView.collectionViewLayout = collectionLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.register(TextbookCardItem.self, forItemWithIdentifier: TextbookCardItem.identifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = LibraryPalette.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let privacyIcon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) ?? NSImage())
        privacyIcon.contentTintColor = LibraryPalette.secondaryText
        privacyIcon.translatesAutoresizingMaskIntoConstraints = false
        let privacyLabel = NSTextField(labelWithString: "PDFs stay in their original folders.")
        privacyLabel.font = .systemFont(ofSize: 12)
        privacyLabel.textColor = LibraryPalette.secondaryText
        privacyLabel.translatesAutoresizingMaskIntoConstraints = false
        let privacy = NSStackView(views: [privacyIcon, privacyLabel])
        privacy.orientation = .horizontal
        privacy.alignment = .centerY
        privacy.spacing = 8
        privacy.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(heading)
        content.addSubview(searchSurface)
        content.addSubview(recentLabel)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(privacy)
        root.addSubview(sidebar)
        root.addSubview(divider)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 268),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 58),
            heading.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            searchSurface.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 28),
            searchSurface.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            searchSurface.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.66),
            searchSurface.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            searchSurface.heightAnchor.constraint(equalToConstant: 58),
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 18),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 15),
            searchIcon.heightAnchor.constraint(equalToConstant: 15),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 9),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor, constant: 1),
            searchField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 22),
            addButton.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -12),
            addButton.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 32),
            addButton.heightAnchor.constraint(equalToConstant: 32),
            recentLabel.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 38),
            recentLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 64),
            scroll.topAnchor.constraint(equalTo: recentLabel.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: recentLabel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -64),
            scroll.bottomAnchor.constraint(equalTo: privacy.topAnchor, constant: -10),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            privacy.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            privacy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            privacyIcon.widthAnchor.constraint(equalToConstant: 13),
            privacyIcon.heightAnchor.constraint(equalToConstant: 13)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredTextbooks.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        let availableWidth = collectionView.bounds.width
        let columns: CGFloat
        if availableWidth >= 880 {
            columns = 4
        } else if availableWidth >= 650 {
            columns = 3
        } else {
            columns = 2
        }
        let totalSpacing = collectionLayout.minimumInteritemSpacing * (columns - 1)
        return NSSize(width: floor((availableWidth - totalSpacing) / columns), height: 326)
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: TextbookCardItem.identifier, for: indexPath)
        guard let card = item as? TextbookCardItem else { return item }
        card.onOpen = { [weak self] textbook in self?.open(textbook) }
        card.onRetry = { [weak self] textbook in self?.retry(textbook) }
        card.onLocate = { [weak self] textbook in self?.locate(textbook) }
        card.onRemove = { [weak self] textbook in self?.remove(textbook) }
        card.configure(textbook: filteredTextbooks[indexPath.item])
        return card
    }

    func importFolder() { addFolder() }

    private func makeSidebar() -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.wantsLayer = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Axiom")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = LibraryPalette.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false

        let sidebarSearch = NSButton()
        sidebarSearch.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search library")
        sidebarSearch.imagePosition = .imageOnly
        sidebarSearch.isBordered = false
        sidebarSearch.contentTintColor = LibraryPalette.primaryText
        sidebarSearch.target = self
        sidebarSearch.action = #selector(focusLibrarySearch)
        sidebarSearch.toolTip = "Search library"
        sidebarSearch.translatesAutoresizingMaskIntoConstraints = false

        let library = makeNavigationRow(title: "Library", symbol: "books.vertical", selected: true)
        let classes = makeNavigationRow(title: "Classes", symbol: "person.3", badge: "Soon", action: #selector(showClassesSoon))
        let studyPlan = makeNavigationRow(title: "Study Plan", symbol: "calendar", badge: "Soon", action: #selector(showStudyPlanSoon))
        let settings = makeNavigationRow(title: "Settings", symbol: "gearshape", action: #selector(showSettingsSoon))

        sidebar.addSubview(title)
        sidebar.addSubview(sidebarSearch)
        sidebar.addSubview(library)
        sidebar.addSubview(classes)
        sidebar.addSubview(studyPlan)
        sidebar.addSubview(settings)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 54),
            title.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            sidebarSearch.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            sidebarSearch.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            sidebarSearch.widthAnchor.constraint(equalToConstant: 32),
            sidebarSearch.heightAnchor.constraint(equalToConstant: 32),
            title.trailingAnchor.constraint(lessThanOrEqualTo: sidebarSearch.leadingAnchor, constant: -12),
            library.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 30),
            library.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            library.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            classes.topAnchor.constraint(equalTo: library.bottomAnchor, constant: 8),
            classes.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            classes.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            studyPlan.topAnchor.constraint(equalTo: classes.bottomAnchor, constant: 8),
            studyPlan.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            studyPlan.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            settings.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            settings.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22)
        ])
        return sidebar
    }

    private func makeNavigationRow(
        title: String,
        symbol: String,
        selected: Bool = false,
        badge: String? = nil,
        action: Selector? = nil
    ) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 11
        row.layer?.backgroundColor = selected
            ? NSColor(calibratedWhite: 1, alpha: 0.11).cgColor
            : NSColor.clear.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        icon.contentTintColor = LibraryPalette.primaryText
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.textColor = LibraryPalette.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.isTransparent = true
        button.isEnabled = true
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        row.addSubview(titleLabel)

        var constraints = [
            row.heightAnchor.constraint(equalToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ]
        if let badge {
            let badgeLabel = NSButton(title: badge, target: nil, action: nil)
            badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
            badgeLabel.contentTintColor = LibraryPalette.secondaryText
            badgeLabel.alignment = .center
            badgeLabel.isBordered = false
            badgeLabel.wantsLayer = true
            badgeLabel.layer?.backgroundColor = LibraryPalette.raised.cgColor
            badgeLabel.layer?.cornerRadius = 7
            badgeLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(badgeLabel)
            constraints.append(contentsOf: [
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeLabel.leadingAnchor, constant: -8),
                badgeLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
                badgeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                badgeLabel.widthAnchor.constraint(equalToConstant: 44),
                badgeLabel.heightAnchor.constraint(equalToConstant: 22)
            ])
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12))
        }
        row.addSubview(button)
        constraints.append(contentsOf: [
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        NSLayoutConstraint.activate(constraints)
        return row
    }

    @objc private func focusLibrarySearch() {
        view.window?.makeFirstResponder(searchField)
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let didAccess = folder.startAccessingSecurityScopedResource()
        let entries = PDFDiscovery.pdfURLs(in: folder).map { url in
            (url: url, bookmark: TextbookURLResolver.bookmark(for: url))
        }
        if didAccess { folder.stopAccessingSecurityScopedResource() }
        guard !entries.isEmpty else {
            presentError("No PDF files were found in \(folder.lastPathComponent).")
            return
        }

        Task {
            for entry in entries {
                do {
                    let textbook = try await store.registerTextbook(url: entry.url, bookmark: entry.bookmark)
                    refresh()
                    startExtraction(textbookID: textbook.id, url: entry.url)
                } catch {
                    presentError(error.localizedDescription)
                }
            }
        }
    }

    private func open(_ textbook: TextbookSummary) {
        if TextbookURLResolver.resolve(textbook) == nil {
            locate(textbook)
        } else {
            onOpen(textbook)
        }
    }

    private func retry(_ textbook: TextbookSummary) {
        guard let url = TextbookURLResolver.resolve(textbook) else { return }
        startExtraction(textbookID: textbook.id, url: url)
    }

    private func remove(_ textbook: TextbookSummary) {
        let alert = NSAlert()
        alert.messageText = "Remove from Library?"
        alert.informativeText = "Axiom will forget \"\(textbook.displayName)\". The original PDF will not be deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await store.removeTextbook(id: textbook.id)
                refresh()
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func locate(_ textbook: TextbookSummary) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.updateReference(id: textbook.id, url: url, bookmark: TextbookURLResolver.bookmark(for: url))
                refresh()
                startExtraction(textbookID: textbook.id, url: url)
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func startExtraction(textbookID: Int64, url: URL) {
        guard activeExtractions.insert(textbookID).inserted else { return }
        if progressTask == nil {
            progressTask = Task { [weak self] in
                guard let self else { return }
                while !self.activeExtractions.isEmpty {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    self.refresh()
                }
                self.progressTask = nil
            }
        }
        Task {
            await extractor.extract(textbookID: textbookID, url: url, store: store)
            activeExtractions.remove(textbookID)
            refresh()
        }
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                textbooks = try await store.listTextbooks()
                guard !Task.isCancelled else { return }
                applyFilter()
                for textbook in textbooks where textbook.extractionStatus == "extracting" {
                    if let url = TextbookURLResolver.resolve(textbook) {
                        startExtraction(textbookID: textbook.id, url: url)
                    }
                }
            } catch {
                presentError(error.localizedDescription)
            }
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredTextbooks = query.isEmpty
            ? textbooks
            : textbooks.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
        collectionView.reloadData()
        recentLabel.stringValue = query.isEmpty ? "Recent" : "Search Results"
        if textbooks.isEmpty {
            emptyLabel.stringValue = "Add a folder of PDFs to build your library."
        } else if filteredTextbooks.isEmpty {
            emptyLabel.stringValue = "No textbooks match \"\(query)\"."
        }
        emptyLabel.isHidden = !filteredTextbooks.isEmpty
    }

    @objc private func showClassesSoon() { presentComingSoon("Classes") }
    @objc private func showStudyPlanSoon() { presentComingSoon("Study Plan") }
    @objc private func showSettingsSoon() { presentComingSoon("Settings") }

    private func presentComingSoon(_ feature: String) {
        let alert = NSAlert()
        alert.messageText = "\(feature) is coming soon"
        alert.informativeText = "This prototype starts with the textbook library. \(feature) will become part of the broader Axiom study workspace."
        alert.runModal()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Axiom"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class ReaderViewController: NSViewController {
    private enum ToolbarMetrics {
        static let titlebarSafetyHeight: CGFloat = 28
        static let controlRowHeight: CGFloat = 52
        static let totalHeight = titlebarSafetyHeight + controlRowHeight
        static let controlCenterFromBottom = controlRowHeight / 2
    }

    private let textbook: TextbookSummary
    private let store: TextbookStore
    private let analyzer: ConfiguredMathAnalyzer
    private let onBack: () -> Void
    private let pdfView = PDFView()
    private let petOverlay = PetOverlayView()
    private let sidebar = NSTextView()
    private let pageLabel = NSTextField(labelWithString: "Opening textbook...")
    private let previousPageButton = NSButton()
    private let nextPageButton = NSButton()
    private var document: PDFDocument?
    private var pageDebounceTask: Task<Void, Never>?
    private var analysisWorker: Task<Void, Never>?
    private var pendingPageIndex: Int?
    private var currentPageIndex = 0
    private var securityScopedURL: URL?
    private var petPosition = CodexPetPositionStore.load()

    init(textbook: TextbookSummary, store: TextbookStore, analyzer: ConfiguredMathAnalyzer, onBack: @escaping () -> Void) {
        self.textbook = textbook
        self.store = store
        self.analyzer = analyzer
        self.onBack = onBack
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.061,
            blue: 0.075,
            alpha: 1
        ).cgColor
        let toolbar = makeToolbar()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor(
            calibratedRed: 0.055,
            green: 0.061,
            blue: 0.075,
            alpha: 1
        )
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.isEditable = false
        sidebar.drawsBackground = true
        sidebar.backgroundColor = .textBackgroundColor
        sidebar.textContainerInset = NSSize(width: 14, height: 14)

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(pdfView)
        root.addSubview(petOverlay)
        root.addSubview(sidebarScroll)
        petOverlay.frame.size = PetOverlayView.defaultSize
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: ToolbarMetrics.totalHeight),
            pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            pdfView.trailingAnchor.constraint(equalTo: sidebarScroll.leadingAnchor, constant: -10),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            pdfView.widthAnchor.constraint(greaterThanOrEqualToConstant: 620),
            sidebarScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 360)
        ])
        view = root
        petOverlay.configureDragging(
            movementBoundsProvider: { [weak self] in self?.petMovementBounds ?? .zero },
            onDragEnded: { [weak self] frame in
                guard let self else { return }
                self.petPosition = CodexPetPositioning.normalizedPosition(
                    for: frame,
                    in: self.petMovementBounds
                )
                CodexPetPositionStore.save(self.petPosition)
            }
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        openTextbook()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !petOverlay.isDragging else { return }
        petOverlay.frame = CodexPetPositioning.frame(
            in: petMovementBounds,
            size: PetOverlayView.defaultSize,
            normalizedPosition: petPosition
        )
    }

    private var petMovementBounds: NSRect {
        pdfView.frame.insetBy(dx: 8, dy: 8)
    }

    private func makeToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(
            calibratedRed: 0.095,
            green: 0.105,
            blue: 0.125,
            alpha: 1
        ).cgColor
        toolbar.appearance = NSAppearance(named: .darkAqua)

        let appName = NSTextField(labelWithString: "Axiom")
        appName.font = .systemFont(ofSize: 16, weight: .bold)
        appName.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        appName.translatesAutoresizingMaskIntoConstraints = false

        let back = NSButton(title: "Library", target: self, action: #selector(backAction))
        back.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "Back to library")
        back.imagePosition = .imageLeading
        back.bezelStyle = .texturedRounded
        back.contentTintColor = .white
        back.translatesAutoresizingMaskIntoConstraints = false

        let bookTitle = NSTextField(labelWithString: textbook.displayName)
        bookTitle.font = .systemFont(ofSize: 15, weight: .medium)
        bookTitle.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
        bookTitle.alignment = .center
        bookTitle.lineBreakMode = .byTruncatingMiddle
        bookTitle.translatesAutoresizingMaskIntoConstraints = false

        configureToolbarIconButton(
            previousPageButton,
            symbolName: "chevron.left",
            accessibilityDescription: "Previous page",
            action: #selector(previousPage)
        )
        configureToolbarIconButton(
            nextPageButton,
            symbolName: "chevron.right",
            accessibilityDescription: "Next page",
            action: #selector(nextPage)
        )

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        pageLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        pageLabel.alignment = .center
        pageLabel.lineBreakMode = .byTruncatingTail
        pageLabel.translatesAutoresizingMaskIntoConstraints = false

        let retry = NSButton()
        configureToolbarIconButton(
            retry,
            symbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh page analysis",
            action: #selector(retryPage)
        )
        retry.toolTip = "Refresh page analysis"

        let leftGroup = NSStackView(views: [appName, back])
        leftGroup.orientation = .horizontal
        leftGroup.alignment = .centerY
        leftGroup.spacing = 18
        leftGroup.translatesAutoresizingMaskIntoConstraints = false

        let pageControls = NSStackView(views: [previousPageButton, pageLabel, nextPageButton, retry])
        pageControls.orientation = .horizontal
        pageControls.alignment = .centerY
        pageControls.spacing = 8
        pageControls.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(leftGroup)
        toolbar.addSubview(bookTitle)
        toolbar.addSubview(pageControls)
        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 20),
            leftGroup.centerYAnchor.constraint(
                equalTo: toolbar.bottomAnchor,
                constant: -ToolbarMetrics.controlCenterFromBottom
            ),
            leftGroup.widthAnchor.constraint(lessThanOrEqualToConstant: 250),

            bookTitle.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            bookTitle.centerYAnchor.constraint(equalTo: leftGroup.centerYAnchor),
            bookTitle.leadingAnchor.constraint(greaterThanOrEqualTo: leftGroup.trailingAnchor, constant: 24),
            bookTitle.trailingAnchor.constraint(lessThanOrEqualTo: pageControls.leadingAnchor, constant: -24),

            pageControls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -20),
            pageControls.centerYAnchor.constraint(equalTo: leftGroup.centerYAnchor),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            previousPageButton.widthAnchor.constraint(equalToConstant: 34),
            nextPageButton.widthAnchor.constraint(equalToConstant: 34),
            retry.widthAnchor.constraint(equalToConstant: 34)
        ])
        updatePageControls()
        return toolbar
    }

    private func configureToolbarIconButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityDescription: String,
        action: Selector
    ) {
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.toolTip = accessibilityDescription
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func updatePageControls() {
        guard let document else {
            pageLabel.stringValue = "Opening textbook..."
            previousPageButton.isEnabled = false
            nextPageButton.isEnabled = false
            return
        }
        pageLabel.stringValue = "Page \(currentPageIndex + 1) of \(document.pageCount)"
        previousPageButton.isEnabled = currentPageIndex > 0
        nextPageButton.isEnabled = currentPageIndex + 1 < document.pageCount
    }

    private func openTextbook() {
        guard let url = TextbookURLResolver.resolve(textbook) else {
            petOverlay.setActivityState(.failed)
            pageLabel.stringValue = "Unavailable"
            renderSidebar(status: "Unavailable", passages: [], note: "The referenced PDF could not be opened.")
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        guard let document = PDFDocument(url: url) else {
            petOverlay.setActivityState(.failed)
            if didAccess { url.stopAccessingSecurityScopedResource() }
            pageLabel.stringValue = "Unavailable"
            renderSidebar(status: "Unavailable", passages: [], note: "PDFKit could not open the referenced file.")
            return
        }
        if didAccess { securityScopedURL = url }
        self.document = document
        pdfView.document = document
        pdfView.autoScales = true
        updatePageControls()
        petOverlay.setActivityState(.idle)
        renderSidebar(status: "Not analyzed", passages: [], note: "AI runs only when this page is visible.")
        scheduleCurrentPage()
    }

    @objc private func pageChanged() {
        guard let document, let currentPage = pdfView.currentPage else { return }
        currentPageIndex = document.index(for: currentPage)
        updatePageControls()
        scheduleCurrentPage()
    }

    private func scheduleCurrentPage() {
        pageDebounceTask?.cancel()
        let pageIndex = currentPageIndex
        petOverlay.setActivityState(.idle)
        renderSidebar(status: "Checking cache", passages: [], note: "Page \(pageIndex + 1) will be analyzed only if no valid cached result exists.")
        pageDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.enqueue(pageIndex)
        }
    }

    private func enqueue(_ pageIndex: Int) {
        pendingPageIndex = pageIndex
        guard analysisWorker == nil else { return }
        analysisWorker = Task { [weak self] in
            guard let self else { return }
            while let pageIndex = self.pendingPageIndex {
                self.pendingPageIndex = nil
                await self.process(pageIndex: pageIndex)
            }
            self.analysisWorker = nil
        }
    }

    private func process(pageIndex: Int) async {
        let lookupStarted = ContinuousClock.now
        do {
            let cache = try await store.cachedAnalysis(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity)
            AxiomLogger.info(
                "Page cache lookup. textbookID=\(textbook.id), page=\(pageIndex + 1), durationMs=\(AxiomLogger.durationMilliseconds(since: lookupStarted))"
            )
            switch cache {
            case let .ready(highlights):
                AxiomLogger.info("Page cache hit. textbookID=\(textbook.id), page=\(pageIndex + 1), highlights=\(highlights.count)")
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.review)
                    render(highlights.map(\.passage), status: highlights.isEmpty ? "No highlights found" : "Highlighted", note: "Loaded from local metadata cache.")
                }
                return
            case let .failed(message):
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.failed)
                    renderSidebar(status: "Failed", passages: [], note: message)
                }
                return
            case .analyzing:
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.running)
                    renderSidebar(status: "Analyzing", passages: [], note: "This page analysis is already running.")
                }
                return
            case .missing:
                AxiomLogger.info("Page cache miss. textbookID=\(textbook.id), page=\(pageIndex + 1), reason=missing_or_invalid_identity")
            }

            guard analyzer.isConfigured else {
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.waiting)
                    renderSidebar(status: "Not analyzed", passages: [], note: analyzer.missingConfigurationMessage)
                }
                return
            }
            guard let page = try await ensureStoredPage(pageIndex) else {
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.waiting)
                    renderSidebar(status: "Not analyzed", passages: [], note: "Local text metadata is not available for this page.")
                }
                return
            }
            guard page.extractionStatus == "ready", !page.text.isEmpty else {
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.waiting)
                    renderSidebar(status: "OCR required", passages: [], note: "This page has no embedded text.")
                }
                return
            }

            try await store.markAnalyzing(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity)
            if currentPageIndex == pageIndex {
                petOverlay.setActivityState(.running)
                renderSidebar(status: "Analyzing", passages: [], note: "\(analyzer.providerName) is selecting important text from page \(pageIndex + 1).")
            }
            let passages = try await analyzeWithRetry(page: PageText(pageIndex: pageIndex, text: page.text))
            let persistStarted = ContinuousClock.now
            try await store.saveAnalysis(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity, passages: passages)
            AxiomLogger.info(
                "Page analysis persisted. textbookID=\(textbook.id), page=\(pageIndex + 1), passages=\(passages.count), durationMs=\(AxiomLogger.durationMilliseconds(since: persistStarted))"
            )
            if currentPageIndex == pageIndex {
                petOverlay.setActivityState(.review)
                render(passages, status: passages.isEmpty ? "No highlights found" : "Highlighted", note: "Saved to the local metadata cache.")
            }
        } catch {
            try? await store.failAnalysis(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity, error: error.localizedDescription)
            AxiomLogger.error("Page analysis failed. textbookID=\(textbook.id), page=\(pageIndex + 1), error=\(error.localizedDescription)")
            if currentPageIndex == pageIndex {
                petOverlay.setActivityState(.failed)
                renderSidebar(status: "Failed", passages: [], note: error.localizedDescription)
            }
        }
    }

    private func ensureStoredPage(_ pageIndex: Int) async throws -> StoredPage? {
        if let page = try await store.page(textbookID: textbook.id, pageIndex: pageIndex) { return page }
        guard let text = document?.page(at: pageIndex)?.string else { return nil }
        let started = ContinuousClock.now
        try await store.saveExtractedPage(textbookID: textbook.id, pageIndex: pageIndex, text: text)
        AxiomLogger.info(
            "Visible page metadata extracted on demand. textbookID=\(textbook.id), page=\(pageIndex + 1), durationMs=\(AxiomLogger.durationMilliseconds(since: started)), aiRequests=0"
        )
        return try await store.page(textbookID: textbook.id, pageIndex: pageIndex)
    }

    private func analyzeWithRetry(page: PageText) async throws -> [ImportantPassage] {
        var attempt = 0
        while true {
            do {
                return try await analyzer.passages(page: page)
            } catch let error as RemoteAnalyzerError where error.isRetryable && attempt < 2 {
                attempt += 1
                let delay = attempt == 1 ? 1 : 2
                AxiomLogger.info("Retrying page analysis. page=\(page.pageIndex + 1), attempt=\(attempt + 1), delaySeconds=\(delay)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func render(_ passages: [ImportantPassage], status: String, note: String) {
        guard let document, let page = document.page(at: currentPageIndex) else { return }
        let renderStarted = ContinuousClock.now
        for annotation in page.annotations where annotation.userName == "AxiomAutoHighlight" {
            page.removeAnnotation(annotation)
        }
        var annotationCount = 0
        for passage in passages where passage.pageIndex == currentPageIndex {
            guard let selection = page.selection(for: passage.range) else { continue }
            for line in selection.selectionsByLine() {
                let annotation = PDFAnnotation(bounds: line.bounds(for: page).insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.55)
                annotation.userName = "AxiomAutoHighlight"
                page.addAnnotation(annotation)
                annotationCount += 1
            }
        }
        pdfView.setNeedsDisplay(pdfView.bounds)
        AxiomLogger.info(
            "Page annotations rendered. page=\(currentPageIndex + 1), passages=\(passages.count), annotations=\(annotationCount), durationMs=\(AxiomLogger.durationMilliseconds(since: renderStarted))"
        )
        renderSidebar(status: status, passages: passages, note: note)
    }

    private func renderSidebar(status: String, passages: [ImportantPassage], note: String) {
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(string: "Page \(currentPageIndex + 1)\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        content.append(NSAttributedString(string: "\(status)\n\n", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
        content.append(NSAttributedString(string: "\(note)\n\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        if passages.isEmpty {
            content.append(NSAttributedString(string: "No highlight details for this page.", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        for (index, passage) in passages.enumerated() {
            content.append(NSAttributedString(string: "\(index + 1). \(passage.kind) - score \(passage.score)\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]))
            content.append(NSAttributedString(string: "\(passage.sentence)\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
            content.append(NSAttributedString(string: "\(passage.explanation)\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            if !passage.concepts.isEmpty {
                content.append(NSAttributedString(string: "Concepts: \(passage.concepts.joined(separator: ", "))\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            content.append(NSAttributedString(string: "\n"))
        }
        sidebar.textStorage?.setAttributedString(content)
    }

    @objc private func retryPage() {
        let pageIndex = currentPageIndex
        petOverlay.setActivityState(.running)
        Task {
            try? await store.clearAnalysis(textbookID: textbook.id, pageIndex: pageIndex)
            enqueue(pageIndex)
        }
    }

    @objc private func previousPage() {
        goToPage(at: currentPageIndex - 1)
    }

    @objc private func nextPage() {
        goToPage(at: currentPageIndex + 1)
    }

    private func goToPage(at index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        pdfView.go(to: page)
    }

    @objc private func backAction() { onBack() }
}

@MainActor
final class AppCoordinator {
    private let window: NSWindow
    private let store: TextbookStore
    private let extractor = TextbookMetadataExtractor()
    private let analyzer = ConfiguredMathAnalyzer()
    private var library: LibraryViewController?

    init(window: NSWindow) throws {
        self.window = window
        store = try TextbookStore()
        Task { try? await store.resetInterruptedAnalysis() }
    }

    func showLibrary() {
        let library = LibraryViewController(store: store, extractor: extractor) { [weak self] textbook in
            self?.showReader(textbook)
        }
        self.library = library
        window.contentViewController = library
        window.title = "Axiom Textbooks"
    }

    func importFolder() {
        showLibrary()
        library?.importFolder()
    }

    private func showReader(_ textbook: TextbookSummary) {
        let reader = ReaderViewController(textbook: textbook, store: store, analyzer: analyzer) { [weak self] in
            self?.showLibrary()
        }
        window.contentViewController = reader
        window.title = textbook.displayName
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum WindowMetrics {
        static let initialSize = NSSize(width: 1440, height: 900)
        static let minimumSize = NSSize(width: 1120, height: 760)
    }

    private var window: NSWindow?
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WindowMetrics.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = WindowMetrics.minimumSize
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        if let logo = AxiomBrand.logo {
            NSApplication.shared.applicationIconImage = logo
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        configureMenu()
        do {
            coordinator = try AppCoordinator(window: window)
            coordinator?.showLibrary()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let fileItem = NSMenuItem()
        menu.addItem(appItem)
        menu.addItem(fileItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Axiom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let fileMenu = NSMenu(title: "File")
        let addFolderItem = NSMenuItem(title: "Add Textbook Folder...", action: #selector(addFolderFromMenu), keyEquivalent: "o")
        addFolderItem.target = self
        fileMenu.addItem(addFolderItem)
        fileItem.submenu = fileMenu
        NSApplication.shared.mainMenu = menu
    }

    @objc private func addFolderFromMenu() { coordinator?.importFolder() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

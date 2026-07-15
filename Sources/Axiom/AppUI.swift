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

@MainActor
final class TextbookRowView: NSTableCellView {
    private let cover = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 4
        cover.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        cover.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cover)
        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cover.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cover.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            cover.widthAnchor.constraint(equalToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -3),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(textbook: TextbookSummary) {
        titleLabel.stringValue = textbook.displayName
        let status: String
        switch textbook.extractionStatus {
        case "ready": status = "Ready - \(textbook.pageCount) pages - local metadata complete"
        case "failed": status = "Metadata failed - \(textbook.error ?? "Retry required")"
        default: status = "Extracting locally - \(textbook.extractedPages) of \(textbook.pageCount) pages"
        }
        detailLabel.stringValue = status
        cover.image = nil
        if let url = TextbookURLResolver.resolve(textbook) {
            let didAccess = url.startAccessingSecurityScopedResource()
            if let document = PDFDocument(url: url) {
                cover.image = document.page(at: 0)?.thumbnail(of: NSSize(width: 112, height: 160), for: .cropBox)
            }
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
    }
}

@MainActor
final class LibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: TextbookStore
    private let extractor: TextbookMetadataExtractor
    private let onOpen: (TextbookSummary) -> Void
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "Add a folder containing textbook PDFs to begin.")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry Metadata", target: nil, action: nil)
    private let locateButton = NSButton(title: "Locate PDF", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private var textbooks: [TextbookSummary] = []
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
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Textbooks")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let addButton = NSButton(title: "Add Folder", target: self, action: #selector(addFolder))
        addButton.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: "Add textbook folder")
        addButton.imagePosition = .imageLeading
        addButton.toolTip = "Reference all PDFs in a folder"
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)
        header.addSubview(addButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("textbook"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 96
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        tableView.selectionHighlightStyle = .regular

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.translatesAutoresizingMaskIntoConstraints = false
        configure(openButton, action: #selector(openSelected))
        configure(retryButton, action: #selector(retrySelected))
        configure(locateButton, action: #selector(locateSelected))
        configure(removeButton, action: #selector(removeSelected))
        actions.addArrangedSubview(openButton)
        actions.addArrangedSubview(retryButton)
        actions.addArrangedSubview(locateButton)
        actions.addArrangedSubview(removeButton)

        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(actions)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 72),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            actions.heightAnchor.constraint(equalToConstant: 30),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        view = root
        updateActionState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { textbooks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("TextbookRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TextbookRowView ?? TextbookRowView()
        cell.identifier = identifier
        cell.configure(textbook: textbooks[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateActionState() }

    func importFolder() { addFolder() }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private var selected: TextbookSummary? {
        guard textbooks.indices.contains(tableView.selectedRow) else { return nil }
        return textbooks[tableView.selectedRow]
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

    @objc private func openSelected() {
        guard let selected else { return }
        if TextbookURLResolver.resolve(selected) == nil {
            locate(selected)
        } else {
            onOpen(selected)
        }
    }

    @objc private func retrySelected() {
        guard let selected, let url = TextbookURLResolver.resolve(selected) else { return }
        startExtraction(textbookID: selected.id, url: url)
    }

    @objc private func locateSelected() {
        guard let selected else { return }
        locate(selected)
    }

    @objc private func removeSelected() {
        guard let selected else { return }
        Task {
            do {
                try await store.removeTextbook(id: selected.id)
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
                tableView.reloadData()
                emptyLabel.isHidden = !textbooks.isEmpty
                updateActionState()
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

    private func updateActionState() {
        let hasSelection = selected != nil
        openButton.isEnabled = hasSelection
        retryButton.isEnabled = hasSelection
        locateButton.isEnabled = hasSelection
        removeButton.isEnabled = hasSelection
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
    private let textbook: TextbookSummary
    private let store: TextbookStore
    private let analyzer: ConfiguredMathAnalyzer
    private let onBack: () -> Void
    private let pdfView = PDFView()
    private let sidebar = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Opening textbook...")
    private var document: PDFDocument?
    private var pageDebounceTask: Task<Void, Never>?
    private var analysisWorker: Task<Void, Never>?
    private var pendingPageIndex: Int?
    private var currentPageIndex = 0
    private var securityScopedURL: URL?

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
        let toolbar = makeToolbar()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
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
        root.addSubview(sidebarScroll)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        openTextbook()
    }

    private func makeToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let back = NSButton(title: "Library", target: self, action: #selector(backAction))
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to library")
        back.imagePosition = .imageLeading
        back.bezelStyle = .rounded
        back.translatesAutoresizingMaskIntoConstraints = false
        let retry = NSButton(title: "Retry Page", target: self, action: #selector(retryPage))
        retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry page")
        retry.imagePosition = .imageLeading
        retry.bezelStyle = .rounded
        retry.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingMiddle
        toolbar.addSubview(back)
        toolbar.addSubview(retry)
        toolbar.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            back.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            retry.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 8),
            retry.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: retry.trailingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        return toolbar
    }

    private func openTextbook() {
        guard let url = TextbookURLResolver.resolve(textbook) else {
            statusLabel.stringValue = "The original PDF is unavailable. Return to Library and locate it."
            renderSidebar(status: "Unavailable", passages: [], note: "The referenced PDF could not be opened.")
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        guard let document = PDFDocument(url: url) else {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            statusLabel.stringValue = "The original PDF could not be opened."
            renderSidebar(status: "Unavailable", passages: [], note: "PDFKit could not open the referenced file.")
            return
        }
        if didAccess { securityScopedURL = url }
        self.document = document
        pdfView.document = document
        pdfView.autoScales = true
        statusLabel.stringValue = "\(textbook.displayName) - page 1 of \(document.pageCount)"
        renderSidebar(status: "Not analyzed", passages: [], note: "AI runs only when this page is visible.")
        scheduleCurrentPage()
    }

    @objc private func pageChanged() {
        guard let document, let currentPage = pdfView.currentPage else { return }
        currentPageIndex = document.index(for: currentPage)
        statusLabel.stringValue = "\(textbook.displayName) - page \(currentPageIndex + 1) of \(document.pageCount)"
        scheduleCurrentPage()
    }

    private func scheduleCurrentPage() {
        pageDebounceTask?.cancel()
        let pageIndex = currentPageIndex
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
                if currentPageIndex == pageIndex { render(highlights.map(\.passage), status: highlights.isEmpty ? "No highlights found" : "Highlighted", note: "Loaded from local metadata cache.") }
                return
            case let .failed(message):
                if currentPageIndex == pageIndex { renderSidebar(status: "Failed", passages: [], note: message) }
                return
            case .analyzing:
                if currentPageIndex == pageIndex { renderSidebar(status: "Analyzing", passages: [], note: "This page analysis is already running.") }
                return
            case .missing:
                AxiomLogger.info("Page cache miss. textbookID=\(textbook.id), page=\(pageIndex + 1), reason=missing_or_invalid_identity")
            }

            guard analyzer.isConfigured else {
                if currentPageIndex == pageIndex { renderSidebar(status: "Not analyzed", passages: [], note: analyzer.missingConfigurationMessage) }
                return
            }
            guard let page = try await ensureStoredPage(pageIndex) else {
                if currentPageIndex == pageIndex { renderSidebar(status: "Not analyzed", passages: [], note: "Local text metadata is not available for this page.") }
                return
            }
            guard page.extractionStatus == "ready", !page.text.isEmpty else {
                if currentPageIndex == pageIndex { renderSidebar(status: "OCR required", passages: [], note: "This page has no embedded text.") }
                return
            }

            try await store.markAnalyzing(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity)
            if currentPageIndex == pageIndex { renderSidebar(status: "Analyzing", passages: [], note: "\(analyzer.providerName) is selecting important text from page \(pageIndex + 1).") }
            let passages = try await analyzeWithRetry(page: PageText(pageIndex: pageIndex, text: page.text))
            let persistStarted = ContinuousClock.now
            try await store.saveAnalysis(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity, passages: passages)
            AxiomLogger.info(
                "Page analysis persisted. textbookID=\(textbook.id), page=\(pageIndex + 1), passages=\(passages.count), durationMs=\(AxiomLogger.durationMilliseconds(since: persistStarted))"
            )
            if currentPageIndex == pageIndex {
                render(passages, status: passages.isEmpty ? "No highlights found" : "Highlighted", note: "Saved to the local metadata cache.")
            }
        } catch {
            try? await store.failAnalysis(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity, error: error.localizedDescription)
            AxiomLogger.error("Page analysis failed. textbookID=\(textbook.id), page=\(pageIndex + 1), error=\(error.localizedDescription)")
            if currentPageIndex == pageIndex { renderSidebar(status: "Failed", passages: [], note: error.localizedDescription) }
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
        if let document {
            statusLabel.stringValue = "\(textbook.displayName) - page \(currentPageIndex + 1) of \(document.pageCount) - \(status)"
        }
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
        Task {
            try? await store.clearAnalysis(textbookID: textbook.id, pageIndex: pageIndex)
            enqueue(pageIndex)
        }
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
    private var window: NSWindow?
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
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

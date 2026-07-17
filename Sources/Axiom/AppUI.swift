import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class HighlightAwarePDFView: PDFView {
    var onPointerMoved: ((NSPoint?) -> Void)?
    private var trackingAreaReference: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerMoved?(nil)
        super.mouseExited(with: event)
    }
}

enum FormulaDisplayFormatter {
    static func display(_ formula: String) -> String {
        var result = formula
            .replacingOccurrences(of: #"ˆ\s*([A-Za-z])"#, with: "$1̂", options: .regularExpression)
            .replacingOccurrences(of: #"\r\n?"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\s*([\]\),])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([\[(])\s+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z])\s+\("#, with: "$1(", options: .regularExpression)
            .replacingOccurrences(of: #"̂\s+\("#, with: "̂(", options: .regularExpression)
            .replacingOccurrences(of: #"\)2\b"#, with: ")²", options: .regularExpression)
            .replacingOccurrences(of: #"\]2\b"#, with: "]²", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = result
            .replacingOccurrences(of: "Reducible", with: "")
            .replacingOccurrences(of: "Irreducible", with: "")
            .replacingOccurrences(of: #"\s+([,\]\)])"#, with: "$1", options: .regularExpression)
        result = repairInterleavedLines(in: result)
        return withoutReferenceNumber(alignedLines(in: result))
    }

    static func withoutReferenceNumber(_ formula: String) -> String {
        formula
            .replacingOccurrences(
                of: #"\s*,?\s*\(\d+(?:\.\d+)+\)\s*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The raw PDF span is still the authority for notation. An AI display can improve
    /// layout, but it must not silently lose a hat, bar, or other modifying mark.
    static func preferredDisplay(aiDisplay: String?, source: String) -> String {
        let sourceDisplay = display(source)
        guard let aiDisplay = aiDisplay?.trimmingCharacters(in: .whitespacesAndNewlines),
              !aiDisplay.isEmpty else { return sourceDisplay }
        let cleanedAI = withoutReferenceNumber(aiDisplay)
        return notationMarkCount(in: cleanedAI) < notationMarkCount(in: sourceDisplay)
            ? sourceDisplay
            : cleanedAI
    }

    private static func notationMarkCount(in formula: String) -> Int {
        formula.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.value == 0x0302 || scalar.value == 0x0304 || scalar.value == 0x005E { count += 1 }
        }
    }

    /// PDF text extraction occasionally interleaves the end of the first visual row with
    /// the start of the next one. This repairs the common two-row layout without changing
    /// the meaning of ordinary one-line equations.
    private static func repairInterleavedLines(in formula: String) -> String {
        let compact = formula.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let pattern = #"^(.*?[+−\-]\s*)ˆ\s*=\s*(\[[^\]]+\]\s*²?)\s+([A-Za-z]̂?\([^\)]*\)\]\s*²?)\s*\+\s*(Var\([^\)]*\).*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)),
              match.numberOfRanges == 5,
              let head = substring(compact, match.range(at: 1)),
              let bracket = substring(compact, match.range(at: 2)),
              let carriedTerm = substring(compact, match.range(at: 3)),
              let tail = substring(compact, match.range(at: 4)) else {
            return compact
        }

        // The carried term is the hatted function which PDFKit placed after the
        // second row. Put it back at the end of row one and inside row two.
        let function = carriedTerm.replacingOccurrences(of: #"\]\s*²?$"#, with: "", options: .regularExpression)
        let restoredBracket = bracket.replacingOccurrences(
            of: #"[A-Za-z]\([^\)]*\)(\]\s*²?)$"#,
            with: function + "$1",
            options: .regularExpression
        )
        return "\(head)\(function)]²\n= \(restoredBracket) + \(tail)"
    }

    private static func alignedLines(in formula: String) -> String {
        let normalizedLines = formula
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Keep the visual structure of multi-line display equations. If extraction gave
        // us a single line containing several aligned equalities, put continuations on
        // their own row so the formula reads in the same direction as the PDF.
        return normalizedLines.flatMap { line -> [String] in
            let pieces = line.components(separatedBy: " = ")
            guard pieces.count > 2 else { return [line] }
            return [pieces[0] + " = " + pieces[1]] + pieces.dropFirst(2).map { "= " + $0 }
        }.joined(separator: "\n")
    }

    private static func substring(_ string: String, _ range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: string) else { return nil }
        return String(string[swiftRange])
    }

    static func symbolNotes(for formula: String) -> [String] {
        var notes: [String] = []
        if formula.contains("Y") { notes.append("Y — observed outcome") }
        if formula.contains("f̂") { notes.append("f̂(X) — estimated prediction from inputs X") }
        if formula.contains("ϵ") || formula.contains("ε") { notes.append("ε — irreducible error") }
        if formula.contains("Var") { notes.append("Var(ε) — variance of the irreducible error") }
        if formula.contains("E(") { notes.append("E(·) — the average value") }
        return notes + FormulaNotation.notes(in: formula, excluding: notes)
    }

    static func pseudocode(for formula: String) -> String? {
        guard formula.contains("Var"), formula.contains("=") else { return nil }
        return "prediction = f̂(X)\nerror = Y − prediction\nexpected_error = reducible_error + Var(error)"
    }
}

enum FormulaNotation {
    private static let entries: [(symbols: [String], meaning: String)] = [
        (["Σ", "∑"], "Σ / ∑ — sum: add all indicated values together"),
        (["Π", "∏"], "Π / ∏ — product: multiply all indicated values together"),
        (["∫"], "∫ — integral: add infinitely many tiny pieces across a range"),
        (["∂"], "∂ — partial derivative: how a result changes when one input changes"),
        (["∇"], "∇ — gradient: the direction of fastest increase"),
        (["∞"], "∞ — infinity: continues without end"),
        (["√"], "√ — square root: the number that multiplies by itself to give the value"),
        (["±"], "± — plus or minus: use either the positive or negative version"),
        (["≈"], "≈ — approximately equal to"),
        (["≠"], "≠ — not equal to"),
        (["≤"], "≤ — less than or equal to"),
        (["≥"], "≥ — greater than or equal to"),
        (["∈"], "∈ — belongs to / is an element of a set"),
        (["∉"], "∉ — does not belong to a set"),
        (["⊂", "⊆"], "⊂ / ⊆ — subset: one set is contained in another"),
        (["∪"], "∪ — union: everything in either set"),
        (["∩"], "∩ — intersection: items shared by both sets"),
        (["∀"], "∀ — for every"),
        (["∃"], "∃ — there exists"),
        (["⇒", "→"], "⇒ / → — leads to, maps to, or implies"),
        (["⇔", "↔"], "⇔ / ↔ — if and only if"),
        (["‖"], "‖ ‖ — norm: the size or length of a vector"),
        (["lim"], "lim — limit: the value approached"),
        (["log"], "log — logarithm: the exponent needed to make a number"),
        (["ln"], "ln — natural logarithm"),
        (["exp"], "exp — exponential function"),
        (["α", "β", "γ", "δ", "θ", "λ", "μ", "σ", "π", "ρ", "τ", "φ", "ω"], "Greek letter — a variable or parameter; its precise meaning comes from the surrounding text")
    ]

    static func notes(in formula: String, excluding existing: [String] = []) -> [String] {
        entries.compactMap { entry in
            guard entry.symbols.contains(where: formula.contains),
                  !existing.contains(entry.meaning) else { return nil }
            return entry.meaning
        }.prefix(12).map { $0 }
    }
}

enum FormulaLearningSupport {
    static func explanation(aiExplanation: String, formula: String) -> String {
        let trimmed = aiExplanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed.lowercased().hasPrefix("central displayed equation") else {
            return trimmed
        }
        if formula.contains("Var"), formula.contains("E("), formula.contains("Y") {
            return "This formula measures how far predictions are from the real outcome on average. It splits that total prediction error into a part that can be improved by making a better model and a part caused by unavoidable randomness."
        }
        if formula.contains("Σ") || formula.contains("∑") {
            return "This formula combines many values into one result. The Σ symbol means to calculate each indicated term and add all of them together."
        }
        if formula.contains("∫") {
            return "This formula adds up many tiny pieces continuously to find a total, such as an area, distance, or accumulated change."
        }
        return "This formula is a rule for turning the values on the right into the result on the left. Work through the operations in order, then interpret the final result in the context of the page."
    }

    static func steps(for formula: String) -> String {
        if formula.contains("Var"), formula.contains("E("), formula.contains("Y") {
            return "1. Find the prediction f̂(X).\n2. Compare it with the real outcome Y.\n3. Square that difference so larger mistakes count more.\n4. Average the squared mistakes, then separate the improvable and unavoidable parts."
        }
        if formula.contains("Σ") || formula.contains("∑") {
            return "1. Start at the lower number beneath Σ.\n2. Calculate the expression for each value up to the upper number.\n3. Add those results together."
        }
        if formula.contains("∫") {
            return "1. Identify the range shown below and above ∫.\n2. Treat the expression as tiny pieces across that range.\n3. Add all the pieces to get the total."
        }
        return "1. Identify the input values.\n2. Calculate the right-hand side from left to right.\n3. Use the resulting value as the quantity on the left."
    }
}

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
    static let logo = image(named: "Axiom_logo_transparent")
    static let appIcon = image(named: "Axiom_app_icon")

    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

private enum LibraryPalette {
    static let canvas = NSColor(calibratedRed: 0.095, green: 0.098, blue: 0.106, alpha: 1)
    static let raised = NSColor(calibratedRed: 0.135, green: 0.139, blue: 0.149, alpha: 1)
    static let border = NSColor(calibratedWhite: 1, alpha: 0.12)
    static let control = NSColor(calibratedWhite: 1, alpha: 0.07)
    static let primaryText = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let secondaryText = NSColor(calibratedWhite: 0.66, alpha: 1)
}

private enum ReaderPalette {
    static let canvas = LibraryPalette.canvas
    static let raised = LibraryPalette.raised
    static let toolbar = LibraryPalette.raised
    static let border = LibraryPalette.border
    static let control = LibraryPalette.control
    static let icon = NSColor.white
    static let primaryText = LibraryPalette.primaryText
    static let secondaryText = LibraryPalette.secondaryText
}

@MainActor
private func suppressFocusRings(in view: NSView) {
    view.focusRingType = .none
    for subview in view.subviews {
        suppressFocusRings(in: subview)
    }
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
        suppressFocusRings(in: root)
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

        let heroLogo = NSImageView(image: AxiomBrand.logo ?? NSImage())
        heroLogo.imageScaling = .scaleProportionallyUpOrDown
        heroLogo.translatesAutoresizingMaskIntoConstraints = false

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

        content.addSubview(heroLogo)
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

            heroLogo.topAnchor.constraint(equalTo: content.topAnchor, constant: 40),
            heroLogo.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            heroLogo.widthAnchor.constraint(equalToConstant: 92),
            heroLogo.heightAnchor.constraint(equalToConstant: 92),
            heading.topAnchor.constraint(equalTo: heroLogo.bottomAnchor, constant: 20),
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
        suppressFocusRings(in: root)
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
            badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
            badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
    private let pdfView = HighlightAwarePDFView()
    private let petOverlay = PetOverlayView()
    private let sidebar = NSTextView()
    private let pageLabel = NSTextField(labelWithString: "Opening textbook...")
    private let previousPageButton = NSButton()
    private let nextPageButton = NSButton()
    private var document: PDFDocument?
    private var pageDebounceTask: Task<Void, Never>?
    private var viewportRefreshTask: Task<Void, Never>?
    private var analysisWorker: Task<Void, Never>?
    private var pendingPageIndex: Int?
    private var processingPageIndex: Int?
    private var currentPageIndex = 0
    private var securityScopedURL: URL?
    private var petPosition = CodexPetPositionStore.load()
    private var revealedHighlightKeys: [Int: Set<String>] = [:]
    private var annotationPassages: [ObjectIdentifier: ImportantPassage] = [:]
    private var hoveredAnnotationID: ObjectIdentifier?

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
        root.layer?.backgroundColor = ReaderPalette.canvas.cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        let toolbar = makeToolbar()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = ReaderPalette.canvas
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.onPointerMoved = { [weak self] point in
            self?.updateInspectorHover(at: point)
        }
        sidebar.isEditable = false
        sidebar.drawsBackground = true
        sidebar.backgroundColor = ReaderPalette.raised
        sidebar.textColor = ReaderPalette.primaryText
        sidebar.insertionPointColor = ReaderPalette.primaryText
        sidebar.textContainerInset = NSSize(width: 18, height: 18)

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = true
        sidebarScroll.backgroundColor = ReaderPalette.raised
        sidebarScroll.borderType = .noBorder
        sidebarScroll.contentView.drawsBackground = true
        sidebarScroll.contentView.backgroundColor = ReaderPalette.raised
        sidebarScroll.wantsLayer = true
        sidebarScroll.layer?.borderWidth = 1
        sidebarScroll.layer?.borderColor = ReaderPalette.border.cgColor
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
        suppressFocusRings(in: root)
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
        // The pet's highlight pass owns its frame while it travels across the page.
        // Do not snap it back to its saved resting position during a layout pass.
        guard !petOverlay.isDragging, !petOverlay.isPerformingHighlightPass else { return }
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
        toolbar.layer?.backgroundColor = ReaderPalette.toolbar.cgColor
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = ReaderPalette.border.cgColor
        toolbar.appearance = NSAppearance(named: .darkAqua)

        let backSurface = NSView()
        backSurface.wantsLayer = true
        backSurface.layer?.backgroundColor = ReaderPalette.control.cgColor
        backSurface.layer?.borderWidth = 1
        backSurface.layer?.borderColor = ReaderPalette.border.cgColor
        backSurface.layer?.cornerRadius = 9
        backSurface.translatesAutoresizingMaskIntoConstraints = false

        let backIcon = NSImageView(
            image: NSImage(systemSymbolName: "books.vertical", accessibilityDescription: nil) ?? NSImage()
        )
        backIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        backIcon.contentTintColor = ReaderPalette.icon
        backIcon.translatesAutoresizingMaskIntoConstraints = false

        let backLabel = NSTextField(labelWithString: "Library")
        backLabel.font = .systemFont(ofSize: 13, weight: .medium)
        backLabel.textColor = ReaderPalette.icon
        backLabel.translatesAutoresizingMaskIntoConstraints = false

        let backContent = NSStackView(views: [backIcon, backLabel])
        backContent.orientation = .horizontal
        backContent.alignment = .centerY
        backContent.spacing = 8
        backContent.translatesAutoresizingMaskIntoConstraints = false

        let backButton = NSButton(title: "", target: self, action: #selector(backAction))
        backButton.isBordered = false
        backButton.isTransparent = true
        backButton.toolTip = "Back to library"
        backButton.setAccessibilityLabel("Library")
        backButton.translatesAutoresizingMaskIntoConstraints = false

        backSurface.addSubview(backContent)
        backSurface.addSubview(backButton)
        NSLayoutConstraint.activate([
            backContent.centerXAnchor.constraint(equalTo: backSurface.centerXAnchor),
            backContent.centerYAnchor.constraint(equalTo: backSurface.centerYAnchor),
            backIcon.widthAnchor.constraint(equalToConstant: 16),
            backIcon.heightAnchor.constraint(equalToConstant: 16),
            backButton.topAnchor.constraint(equalTo: backSurface.topAnchor),
            backButton.leadingAnchor.constraint(equalTo: backSurface.leadingAnchor),
            backButton.trailingAnchor.constraint(equalTo: backSurface.trailingAnchor),
            backButton.bottomAnchor.constraint(equalTo: backSurface.bottomAnchor)
        ])

        let bookTitle = NSTextField(labelWithString: textbook.displayName)
        bookTitle.font = .systemFont(ofSize: 15, weight: .medium)
        bookTitle.textColor = ReaderPalette.primaryText
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
        pageLabel.textColor = ReaderPalette.primaryText
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

        let pageControls = NSStackView(views: [previousPageButton, pageLabel, nextPageButton, retry])
        pageControls.orientation = .horizontal
        pageControls.alignment = .centerY
        pageControls.spacing = 8
        pageControls.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backSurface)
        toolbar.addSubview(bookTitle)
        toolbar.addSubview(pageControls)
        NSLayoutConstraint.activate([
            backSurface.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 20),
            backSurface.centerYAnchor.constraint(
                equalTo: toolbar.bottomAnchor,
                constant: -ToolbarMetrics.controlCenterFromBottom
            ),
            backSurface.widthAnchor.constraint(equalToConstant: 116),
            backSurface.heightAnchor.constraint(equalToConstant: 36),

            bookTitle.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            bookTitle.centerYAnchor.constraint(equalTo: backSurface.centerYAnchor),
            bookTitle.leadingAnchor.constraint(greaterThanOrEqualTo: backSurface.trailingAnchor, constant: 24),
            bookTitle.trailingAnchor.constraint(lessThanOrEqualTo: pageControls.leadingAnchor, constant: -24),

            pageControls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -20),
            pageControls.centerYAnchor.constraint(equalTo: backSurface.centerYAnchor),
            pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            previousPageButton.widthAnchor.constraint(equalToConstant: 34),
            previousPageButton.heightAnchor.constraint(equalToConstant: 32),
            nextPageButton.widthAnchor.constraint(equalToConstant: 34),
            nextPageButton.heightAnchor.constraint(equalToConstant: 32),
            retry.widthAnchor.constraint(equalToConstant: 34),
            retry.heightAnchor.constraint(equalToConstant: 32)
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
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = ReaderPalette.control.cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = ReaderPalette.border.cgColor
        button.layer?.cornerRadius = 7
        button.contentTintColor = ReaderPalette.icon
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
        beginObservingViewport()
        updatePageControls()
        petOverlay.setActivityState(.idle)
        renderSidebar(status: "Not analyzed", passages: [], note: "AI runs only when this page is visible.")
        scheduleCurrentPage()
    }

    @objc private func pageChanged() {
        guard let document, let currentPage = pdfView.currentPage else { return }
        currentPageIndex = document.index(for: currentPage)
        // Page changes often fire repeatedly during a fast continuous scroll. Let the
        // viewport settle before retargeting the pet rather than restarting its walk.
        scheduleCurrentPage(after: 500)
        updatePageControls()
    }

    private func scheduleCurrentPage(after milliseconds: Int = 250) {
        pageDebounceTask?.cancel()
        let pageIndex = currentPageIndex
        // The reader only needs an answer for the visible page. Cancelling stale work both
        // makes page turns feel immediate and avoids spending a limited API request on a page
        // the reader has already left.
        if let processingPageIndex, processingPageIndex != pageIndex {
            analysisWorker?.cancel()
        }
        petOverlay.setActivityState(.idle)
        renderSidebar(status: "Checking cache", passages: [], note: "Page \(pageIndex + 1) will be analyzed only if no valid cached result exists.")
        pageDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, let self else { return }
            // Cancel once, immediately before starting the new settled viewport pass.
            // Doing this at every scroll tick caused the pet to flicker and restart.
            self.petOverlay.cancelHighlightPass()
            self.enqueue(pageIndex)
        }
    }

    private func beginObservingViewport() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clipView = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidChangeNotification),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    @objc private func viewportDidChangeNotification(_ notification: Notification) {
        viewportDidChange()
    }

    private func viewportDidChange() {
        viewportRefreshTask?.cancel()
        viewportRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            // Re-evaluate only after the reader settles, so the pet never chases a
            // stale coordinate while the PDF is still moving beneath it.
            self.scheduleCurrentPage(after: 250)
        }
    }

    private func enqueue(_ pageIndex: Int) {
        pendingPageIndex = pageIndex
        guard analysisWorker == nil else { return }
        analysisWorker = Task { [weak self] in
            guard let self else { return }
            while let pageIndex = self.pendingPageIndex {
                self.pendingPageIndex = nil
                self.processingPageIndex = pageIndex
                await self.process(pageIndex: pageIndex)
                self.processingPageIndex = nil
                // A cancelled worker must not be reused: cancellation is sticky for the
                // lifetime of a Swift Task. Start a fresh worker for the latest pending page.
                if Task.isCancelled {
                    self.analysisWorker = nil
                    if let pendingPageIndex = self.pendingPageIndex {
                        self.enqueue(pendingPageIndex)
                    }
                    return
                }
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
                    revealHighlights(
                        highlights.map(\.passage),
                        status: highlights.isEmpty ? "No highlights found" : "Highlighted",
                        note: "Codex is marking the important parts from left to right."
                    )
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

            if let reusable = try await store.reusableAnalysis(
                textFingerprint: page.fingerprint,
                identity: analyzer.identity,
                pageIndex: pageIndex
            ) {
                try await store.saveAnalysis(
                    textbookID: textbook.id,
                    pageIndex: pageIndex,
                    identity: analyzer.identity,
                    passages: reusable
                )
                AxiomLogger.info(
                    "Shared page cache hit. textbookID=\(textbook.id), page=\(pageIndex + 1), passages=\(reusable.count)"
                )
                if currentPageIndex == pageIndex {
                    revealHighlights(
                        reusable,
                        status: reusable.isEmpty ? "No highlights found" : "Highlighted",
                        note: "Loaded from the matching page-text cache."
                    )
                }
                return
            }

            try await store.markAnalyzing(textbookID: textbook.id, pageIndex: pageIndex, identity: analyzer.identity)
            clearRenderedHighlights(on: pageIndex)
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
                revealHighlights(
                    passages,
                    status: passages.isEmpty ? "No highlights found" : "Highlighted",
                    note: "Codex is marking the important parts from left to right."
                )
            }
        } catch {
            if Task.isCancelled {
                try? await store.clearAnalysis(textbookID: textbook.id, pageIndex: pageIndex)
                AxiomLogger.info("Cancelled stale page analysis. textbookID=\(textbook.id), page=\(pageIndex + 1)")
                return
            }
            if let error = error as? RemoteAnalyzerError, error.isRateLimited {
                try? await store.clearAnalysis(textbookID: textbook.id, pageIndex: pageIndex)
                AxiomLogger.info("Page analysis deferred by provider rate limit. textbookID=\(textbook.id), page=\(pageIndex + 1)")
                if currentPageIndex == pageIndex {
                    petOverlay.setActivityState(.waiting)
                    renderSidebar(status: "Rate limited", passages: [], note: error.localizedDescription)
                }
                return
            }
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
            } catch let error as RemoteAnalyzerError where error.isRetryable && attempt < 1 {
                attempt += 1
                let delay = 2
                AxiomLogger.info("Retrying page analysis. page=\(page.pageIndex + 1), attempt=\(attempt + 1), delaySeconds=\(delay)")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func render(_ passages: [ImportantPassage], status: String, note: String) {
        guard let document, let page = document.page(at: currentPageIndex) else { return }
        let renderStarted = ContinuousClock.now
        removeAutoHighlights(from: page)
        var annotationCount = 0
        for passage in passages where passage.pageIndex == currentPageIndex {
            annotationCount += addAnnotations(for: passage, on: page)
        }
        pdfView.setNeedsDisplay(pdfView.bounds)
        AxiomLogger.info(
            "Page annotations rendered. page=\(currentPageIndex + 1), passages=\(passages.count), annotations=\(annotationCount), durationMs=\(AxiomLogger.durationMilliseconds(since: renderStarted))"
        )
        showEmptyInspector()
    }

    private func revealHighlights(_ passages: [ImportantPassage], status: String, note: String) {
        guard let document, let page = document.page(at: currentPageIndex) else { return }
        guard !passages.isEmpty else {
            petOverlay.setActivityState(.review)
            render(passages, status: status, note: note)
            return
        }

        let pageIndex = currentPageIndex
        let ordered = passages
            .filter { $0.pageIndex == pageIndex }
            .sorted { lhs, rhs in
                let lhsBounds = page.selection(for: lhs.range)?.bounds(for: page) ?? .zero
                let rhsBounds = page.selection(for: rhs.range)?.bounds(for: page) ?? .zero
                return lhsBounds.maxY == rhsBounds.maxY ? lhsBounds.minX < rhsBounds.minX : lhsBounds.maxY > rhsBounds.maxY
            }
        let candidates = ordered.compactMap { passage -> (passage: ImportantPassage, target: NSPoint)? in
            let pageBounds = page.selection(for: passage.range)?.bounds(for: page) ?? .zero
            let pdfViewBounds = pdfView.convert(pageBounds, from: page)
            guard pdfView.visibleRect.intersects(pdfViewBounds),
                  !revealedHighlightKeys[pageIndex, default: []].contains(highlightKey(for: passage)) else {
                return nil
            }
            let readerBounds = pdfView.convert(pdfViewBounds, to: view)
            return (passage, NSPoint(x: readerBounds.midX, y: readerBounds.midY))
        }
        guard !candidates.isEmpty else {
            petOverlay.setActivityState(.idle)
            // Highlights were already drawn for this viewport. The sidebar is an inspector,
            // never a second list of highlights, so leave it ready for the next hover.
            showEmptyInspector()
            return
        }
        showEmptyInspector()
        let targetProvider: (Int) -> NSPoint? = { [weak self] index in
            guard let self, candidates.indices.contains(index) else { return nil }
            let passage = candidates[index].passage
            let pageBounds = page.selection(for: passage.range)?.bounds(for: page) ?? .zero
            let pdfViewBounds = self.pdfView.convert(pageBounds, from: page)
            guard self.pdfView.visibleRect.intersects(pdfViewBounds) else { return nil }
            let readerBounds = self.pdfView.convert(pdfViewBounds, to: self.view)
            return NSPoint(x: readerBounds.midX, y: readerBounds.midY)
        }
        petOverlay.performHighlightPass(to: candidates.map(\.target), in: petMovementBounds, targetProvider: targetProvider, onArrival: { [weak self] index in
            guard let self, self.currentPageIndex == pageIndex else { return }
            guard candidates.indices.contains(index) else { return }
            let passage = candidates[index].passage
            _ = self.addAnnotations(for: passage, on: page)
            self.revealedHighlightKeys[pageIndex, default: []].insert(self.highlightKey(for: passage))
            self.pdfView.setNeedsDisplay(self.pdfView.bounds)
        }, completion: { [weak self] in
            guard let self, self.currentPageIndex == pageIndex else { return }
            self.showEmptyInspector()
        })
    }

    @discardableResult
    private func addAnnotations(for passage: ImportantPassage, on page: PDFPage) -> Int {
        guard let selection = page.selection(for: passage.range) else { return 0 }
        var count = 0
        for line in selection.selectionsByLine() {
            let annotation = PDFAnnotation(bounds: line.bounds(for: page).insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
            annotation.color = NSColor.systemYellow.withAlphaComponent(0.55)
            annotation.userName = "AxiomAutoHighlight"
            page.addAnnotation(annotation)
            annotationPassages[ObjectIdentifier(annotation)] = passage
            count += 1
        }
        return count
    }

    private func highlightKey(for passage: ImportantPassage) -> String {
        "\(passage.range.location):\(passage.range.length):\(passage.kind)"
    }

    private func clearRenderedHighlights(on pageIndex: Int) {
        revealedHighlightKeys[pageIndex] = []
        guard let page = document?.page(at: pageIndex) else { return }
        removeAutoHighlights(from: page)
    }

    private func removeAutoHighlights(from page: PDFPage) {
        for annotation in page.annotations where annotation.userName == "AxiomAutoHighlight" {
            annotationPassages.removeValue(forKey: ObjectIdentifier(annotation))
            page.removeAnnotation(annotation)
        }
        hoveredAnnotationID = nil
    }

    private func updateInspectorHover(at point: NSPoint?) {
        guard let point, let annotation = annotation(at: point) else {
            if hoveredAnnotationID != nil {
                hoveredAnnotationID = nil
                showEmptyInspector()
            }
            return
        }
        let id = ObjectIdentifier(annotation)
        guard id != hoveredAnnotationID, let passage = annotationPassages[id] else { return }
        hoveredAnnotationID = id
        showInspector(for: passage)
    }

    private func annotation(at point: NSPoint) -> PDFAnnotation? {
        guard let document else { return nil }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.userName == "AxiomAutoHighlight" {
                let bounds = pdfView.convert(annotation.bounds, from: page)
                if bounds.contains(point) { return annotation }
            }
        }
        return nil
    }

    private func showEmptyInspector() {
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(string: "Highlight details\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        content.append(NSAttributedString(string: "\nHover over a highlight to see why it matters.\n", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        sidebar.textStorage?.setAttributedString(content)
    }

    private func showInspector(for passage: ImportantPassage) {
        let content = NSMutableAttributedString()
        if passage.kind == "equation" {
            let formula = passage.formulaDisplay?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayedFormula = FormulaDisplayFormatter.preferredDisplay(
                aiDisplay: formula,
                source: passage.sentence
            )
            content.append(NSAttributedString(string: "Formula\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
            content.append(NSAttributedString(string: displayedFormula + "\n\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor]))
            appendInspectorSection("What it means", FormulaLearningSupport.explanation(aiExplanation: passage.explanation, formula: displayedFormula), to: content)
            let symbols = FormulaDisplayFormatter.symbolNotes(for: displayedFormula)
            if !symbols.isEmpty { appendInspectorSection("Symbols", symbols.joined(separator: "\n"), to: content) }
            appendInspectorSection("How to use it", FormulaLearningSupport.steps(for: displayedFormula), to: content)
        } else {
            content.append(NSAttributedString(string: "Why this matters\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
            content.append(NSAttributedString(string: passage.sentence + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]))
            appendInspectorSection("Why", passage.explanation, to: content)
            let simpleExplanation = passage.simpleExplanation?.trimmingCharacters(in: .whitespacesAndNewlines)
            appendInspectorSection(
                "In simple terms",
                (simpleExplanation?.isEmpty == false) ? simpleExplanation! : passage.explanation,
                to: content
            )
            if !passage.concepts.isEmpty {
                appendInspectorSection("Connection", "Related: " + passage.concepts.joined(separator: ", ") + ".", to: content)
            }
        }
        sidebar.textStorage?.setAttributedString(content)
    }

    private func appendInspectorSection(_ title: String, _ body: String, to content: NSMutableAttributedString, monospaced: Bool = false) {
        content.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
        content.append(NSAttributedString(string: body + "\n\n", attributes: [.font: monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]))
    }

    private func renderSidebar(status: String, passages: [ImportantPassage], note: String) {
        // The normal sidebar is deliberately an empty hover inspector. In particular, do
        // not reintroduce the old list after a cache hit, page settle, or pet animation.
        // Errors remain visible because they tell the reader what action is needed.
        guard ["Failed", "Rate limited", "OCR required", "Unavailable"].contains(status) else {
            showEmptyInspector()
            return
        }
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(
            string: "Page \(currentPageIndex + 1)\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 18),
                .foregroundColor: ReaderPalette.primaryText
            ]
        ))
        content.append(NSAttributedString(
            string: "\(status)\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: ReaderPalette.secondaryText
            ]
        ))
        content.append(NSAttributedString(
            string: "\(note)\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: ReaderPalette.secondaryText
            ]
        ))
        if passages.isEmpty {
            content.append(NSAttributedString(
                string: "No highlight details for this page.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: ReaderPalette.primaryText
                ]
            ))
        }
        for (index, passage) in passages.enumerated() {
            content.append(NSAttributedString(
                string: "\(index + 1). \(passage.kind) - score \(passage.score)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: ReaderPalette.secondaryText
                ]
            ))
            content.append(NSAttributedString(
                string: "\(passage.sentence)\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: ReaderPalette.primaryText
                ]
            ))
            content.append(NSAttributedString(
                string: "\(passage.explanation)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: ReaderPalette.primaryText
                ]
            ))
            if !passage.concepts.isEmpty {
                content.append(NSAttributedString(
                    string: "Concepts: \(passage.concepts.joined(separator: ", "))\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: ReaderPalette.secondaryText
                    ]
                ))
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
            clearRenderedHighlights(on: pageIndex)
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
final class ContentHostViewController: NSViewController {
    enum Direction {
        case forward
        case backward
    }

    private var currentController: NSViewController?
    private var isTransitioning = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = LibraryPalette.canvas.cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        view = root
    }

    func show(
        _ nextController: NSViewController,
        animated: Bool,
        direction: Direction
    ) {
        guard !isTransitioning else { return }
        nextController.view.frame = view.bounds
        nextController.view.autoresizingMask = [.width, .height]

        guard let currentController else {
            addChild(nextController)
            view.addSubview(nextController.view)
            self.currentController = nextController
            return
        }

        addChild(nextController)
        guard animated else {
            currentController.view.removeFromSuperview()
            currentController.removeFromParent()
            view.addSubview(nextController.view)
            self.currentController = nextController
            return
        }

        isTransitioning = true
        let options: NSViewController.TransitionOptions
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            options = .crossfade
        } else {
            options = direction == .forward ? .slideLeft : .slideRight
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            transition(
                from: currentController,
                to: nextController,
                options: options
            ) { [weak self, weak currentController] in
                MainActor.assumeIsolated {
                    currentController?.removeFromParent()
                    self?.currentController = nextController
                    self?.isTransitioning = false
                }
            }
        }
    }
}

@MainActor
final class AppCoordinator {
    private let window: NSWindow
    private let contentHost = ContentHostViewController()
    private let store: TextbookStore
    private let extractor = TextbookMetadataExtractor()
    private let analyzer = ConfiguredMathAnalyzer()
    private var library: LibraryViewController?

    init(window: NSWindow) throws {
        self.window = window
        store = try TextbookStore()
        window.contentViewController = contentHost
        Task { try? await store.resetInterruptedAnalysis() }
    }

    func showLibrary(animated: Bool = true) {
        let library = LibraryViewController(store: store, extractor: extractor) { [weak self] textbook in
            self?.showReader(textbook)
        }
        self.library = library
        window.title = ""
        configureWindowForLibrary()
        contentHost.show(library, animated: animated, direction: .backward)
    }

    func importFolder() {
        showLibrary(animated: false)
        library?.importFolder()
    }

    private func showReader(_ textbook: TextbookSummary) {
        let reader = ReaderViewController(textbook: textbook, store: store, analyzer: analyzer) { [weak self] in
            self?.showLibrary()
        }
        window.title = textbook.displayName
        configureWindowForReader()
        contentHost.show(reader, animated: true, direction: .forward)
    }

    private func configureWindowForLibrary() {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = LibraryPalette.canvas
    }

    private func configureWindowForReader() {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = ReaderPalette.toolbar
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
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        if let appIcon = AxiomBrand.appIcon {
            NSApplication.shared.applicationIconImage = appIcon
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        configureMenu()
        do {
            coordinator = try AppCoordinator(window: window)
            coordinator?.showLibrary(animated: false)
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

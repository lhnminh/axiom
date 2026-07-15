import Foundation
import PDFKit

enum AxiomVerification {
    static func run() async -> Bool {
        var failures: [String] = []

        check(
            TextFingerprint.make("A measure space\ncontains   a sigma algebra.")
                == TextFingerprint.make("A measure space contains a sigma algebra."),
            "Whitespace normalization",
            failures: &failures
        )

        do {
            try await verifyStore()
            print("PASS SQLite cache identity and persisted highlights")
        } catch {
            failures.append("SQLite cache: \(error.localizedDescription)")
        }

        do {
            try verifyFixtures()
            print("PASS Joined textbook page fingerprints")
        } catch {
            failures.append("PDF fixtures: \(error.localizedDescription)")
        }

        do {
            try await verifyLocalImport()
            print("PASS Eight-page local import without AI analysis")
        } catch {
            failures.append("Local import: \(error.localizedDescription)")
        }

        let discovered = PDFDiscovery.pdfURLs(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("mock-data")
        )
        check(discovered.count == 9, "Folder discovery found all nine PDF fixtures", failures: &failures)

        let petIdleAnimationIsValid = await MainActor.run {
            let frames = CodexPetSprites.idleFrames()
            let uniqueFrames = Set(frames.compactMap(\.tiffRepresentation))
            return frames.count == CodexPetSprites.idleFrameCount
                && frames.allSatisfy { $0.size == CodexPetSprites.frameSize }
                && uniqueFrames.count > 1
        }
        check(petIdleAnimationIsValid, "Codex pet idle animation loaded seven frames with motion", failures: &failures)

        if failures.isEmpty {
            print("Verification complete: all checks passed")
            return true
        }
        for failure in failures { print("FAIL \(failure)") }
        return false
    }

    private static func verifyStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("axiom-verify-\(UUID().uuidString).sqlite3")
        let store = try TextbookStore(databaseURL: url)
        let textbook = try await store.registerTextbook(
            url: URL(fileURLWithPath: "/tmp/axiom-example.pdf"),
            bookmark: nil
        )
        try await store.beginExtraction(textbookID: textbook.id, fingerprint: "book-v1", pageCount: 1)
        try await store.saveExtractedPage(
            textbookID: textbook.id,
            pageIndex: 0,
            text: "Definition: Training error measures fit on observed data."
        )
        try await store.finishExtraction(textbookID: textbook.id)
        let identity = AnalysisIdentity(provider: "Gemini", model: "verify-model", promptVersion: "verify-v1")
        let passage = ImportantPassage(
            pageIndex: 0,
            sentence: "Training error",
            range: NSRange(location: 12, length: 14),
            kind: "concept",
            explanation: "A model-fit measure.",
            score: 7,
            concepts: ["training error"]
        )
        try await store.markAnalyzing(textbookID: textbook.id, pageIndex: 0, identity: identity)
        try await store.saveAnalysis(textbookID: textbook.id, pageIndex: 0, identity: identity, passages: [passage])
        guard case let .ready(highlights) = try await store.cachedAnalysis(
            textbookID: textbook.id,
            pageIndex: 0,
            identity: identity
        ), highlights.count == 1, highlights[0].concepts == ["training error"] else {
            throw VerificationError.failed("Stored highlights were not returned from cache.")
        }
        let changed = AnalysisIdentity(provider: "Gemini", model: "changed-model", promptVersion: "verify-v1")
        guard case .missing = try await store.cachedAnalysis(
            textbookID: textbook.id,
            pageIndex: 0,
            identity: changed
        ) else {
            throw VerificationError.failed("A model change did not invalidate the cache.")
        }
    }

    private static func verifyFixtures() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("mock-data")
        guard let joined = PDFDocument(url: root.appendingPathComponent("ISLP_website-28_merged.pdf")), joined.pageCount == 8 else {
            throw VerificationError.failed("The joined eight-page fixture could not be opened.")
        }
        for sourcePage in 28...35 {
            guard let individual = PDFDocument(url: root.appendingPathComponent("ISLP_website-\(sourcePage).pdf")) else {
                throw VerificationError.failed("Individual page fixture \(sourcePage) could not be opened.")
            }
            let individualText = individual.page(at: 0)?.string ?? ""
            let joinedText = joined.page(at: sourcePage - 28)?.string ?? ""
            guard TextFingerprint.make(individualText) == TextFingerprint.make(joinedText) else {
                throw VerificationError.failed("Joined page \(sourcePage - 27) does not match source page \(sourcePage).")
            }
        }
    }

    private static func verifyLocalImport() async throws {
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("mock-data/ISLP_website-28_merged.pdf")
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("axiom-import-\(UUID().uuidString).sqlite3")
        let store = try TextbookStore(databaseURL: databaseURL)
        let textbook = try await store.registerTextbook(url: fixture, bookmark: nil)
        await TextbookMetadataExtractor().extract(textbookID: textbook.id, url: fixture, store: store)
        guard let imported = try await store.textbook(id: textbook.id),
              imported.pageCount == 8,
              imported.extractedPages == 8,
              imported.extractionStatus == "ready" else {
            throw VerificationError.failed("The joined fixture did not produce eight ready page records.")
        }
        for pageIndex in 0..<8 {
            guard let page = try await store.page(textbookID: textbook.id, pageIndex: pageIndex),
                  !page.text.isEmpty,
                  page.analysisStatus == "not_analyzed" else {
                throw VerificationError.failed("Page \(pageIndex + 1) was not locally extracted or was unexpectedly AI analyzed.")
            }
        }
    }

    private static func check(_ condition: Bool, _ name: String, failures: inout [String]) {
        if condition {
            print("PASS \(name)")
        } else {
            failures.append(name)
        }
    }
}

enum VerificationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}

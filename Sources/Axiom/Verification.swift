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

        do {
            try await verifyCodexPet()
            print("PASS Codex pet animation, interaction, and positioning contract")
        } catch {
            failures.append("Codex pet: \(error.localizedDescription)")
        }

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

    private static func verifyCodexPet() async throws {
        let expectedFrameCounts: [CodexPetAnimationState: Int] = [
            .idle: 6,
            .runningRight: 8,
            .runningLeft: 8,
            .waving: 4,
            .jumping: 5,
            .failed: 8,
            .waiting: 6,
            .running: 6,
            .review: 6
        ]
        for (state, expectedCount) in expectedFrameCounts {
            guard CodexPetAnimationContract.standardFrames(for: state).count == expectedCount else {
                throw VerificationError.failed("\(state.rawValue) has the wrong frame count.")
            }
        }

        let atlasIsValid = await MainActor.run {
            guard CodexPetSprites.isValid else { return false }
            return CodexPetAnimationState.allCases
                .flatMap(CodexPetAnimationContract.standardFrames)
                .allSatisfy {
                    CodexPetSprites.image(for: $0)?.size == CodexPetAnimationContract.cellSize
                }
        }
        guard atlasIsValid else {
            throw VerificationError.failed("The 8-by-11 sprite atlas or one of its 57 animation cells is invalid.")
        }

        let idle = CodexPetAnimationContract.playback(for: .idle, prefersReducedMotion: false)
        guard idle.loopStartIndex == 0,
              durations(idle.frames) == [1.68, 0.66, 0.66, 0.84, 0.84, 1.92] else {
            throw VerificationError.failed("Idle playback does not use Codex's six-times slowdown.")
        }

        let jumping = CodexPetAnimationContract.playback(for: .jumping, prefersReducedMotion: false)
        let expectedJumpingFrames = Array(
            repeating: CodexPetAnimationContract.standardFrames(for: .jumping),
            count: 3
        ).flatMap({ $0 })
        guard jumping.frames.count == 21, jumping.loopStartIndex == 15,
              Array(jumping.frames.prefix(15)) == expectedJumpingFrames,
              Array(jumping.frames.suffix(6)) == CodexPetAnimationContract.slowedIdleFrames else {
            throw VerificationError.failed("Reaction playback does not run three times before settling into idle.")
        }

        for state in CodexPetAnimationState.allCases {
            let reducedMotion = CodexPetAnimationContract.playback(for: state, prefersReducedMotion: true)
            guard reducedMotion.frames == Array(CodexPetAnimationContract.standardFrames(for: state).prefix(1)),
                  reducedMotion.loopStartIndex == nil else {
                throw VerificationError.failed("Reduced motion is not a still first frame for \(state.rawValue).")
            }
        }

        guard CodexPetAnimationContract.dragState(currentState: nil, horizontalDelta: 3.99) == nil,
              CodexPetAnimationContract.dragState(currentState: nil, horizontalDelta: 4) == .runningRight,
              CodexPetAnimationContract.dragState(currentState: .runningRight, horizontalDelta: -4) == .runningLeft,
              CodexPetAnimationContract.dragState(currentState: .runningLeft, horizontalDelta: 0) == .runningLeft,
              CodexPetAnimationContract.effectiveState(activityState: .failed, isHovered: true, dragState: nil) == .jumping,
              CodexPetAnimationContract.effectiveState(activityState: .failed, isHovered: true, dragState: .runningRight) == .runningRight else {
            throw VerificationError.failed("Hover and drag state precedence does not match Codex.")
        }

        let petSize = NSSize(
            width: 80,
            height: 80 * CodexPetAnimationContract.cellSize.height / CodexPetAnimationContract.cellSize.width
        )
        let mascotBounds = NSRect(origin: .zero, size: petSize)
        guard CodexPetLookDirection.frame(mascotBounds: mascotBounds, point: NSPoint(x: mascotBounds.midX, y: mascotBounds.maxY + 1), spriteVersionNumber: 2)
                == CodexPetFrame(rowIndex: 9, columnIndex: 0, frameDuration: 0),
              CodexPetLookDirection.frame(mascotBounds: mascotBounds, point: NSPoint(x: mascotBounds.maxX + 1, y: mascotBounds.midY), spriteVersionNumber: 2)
                == CodexPetFrame(rowIndex: 9, columnIndex: 4, frameDuration: 0),
              CodexPetLookDirection.frame(mascotBounds: mascotBounds, point: NSPoint(x: mascotBounds.midX, y: mascotBounds.minY - 1), spriteVersionNumber: 2)
                == CodexPetFrame(rowIndex: 10, columnIndex: 0, frameDuration: 0),
              CodexPetLookDirection.frame(mascotBounds: mascotBounds, point: NSPoint(x: mascotBounds.minX - 1, y: mascotBounds.midY), spriteVersionNumber: 2)
                == CodexPetFrame(rowIndex: 10, columnIndex: 4, frameDuration: 0),
              CodexPetLookDirection.frame(mascotBounds: mascotBounds, point: NSPoint(x: mascotBounds.midX, y: mascotBounds.midY), spriteVersionNumber: 2) == nil else {
            throw VerificationError.failed("The 16-direction look row mapping is incorrect.")
        }

        let movementBounds = NSRect(x: 10, y: 20, width: 500, height: 400)
        let position = CodexPetNormalizedPosition(x: 0.35, y: 0.7)
        let frame = CodexPetPositioning.frame(
            in: movementBounds,
            size: petSize,
            normalizedPosition: position
        )
        let roundTrip = CodexPetPositioning.normalizedPosition(for: frame, in: movementBounds)
        let outOfBounds = NSRect(x: -200, y: 900, width: frame.width, height: frame.height)
        let clamped = CodexPetPositioning.clampedOrigin(for: outOfBounds, in: movementBounds)
        let defaultsSuite = "axiom-pet-verify-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw VerificationError.failed("A temporary defaults suite could not be created.")
        }
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        CodexPetPositionStore.save(position, defaults: defaults)
        let restoredPosition = CodexPetPositionStore.load(defaults: defaults)
        guard approximatelyEqual(roundTrip.x, position.x),
              approximatelyEqual(roundTrip.y, position.y),
              restoredPosition == position,
              clamped.x == movementBounds.minX,
              clamped.y == movementBounds.maxY - outOfBounds.height else {
            throw VerificationError.failed("Saved or clamped drag positioning is incorrect.")
        }
    }

    private static func durations(_ frames: [CodexPetFrame]) -> [TimeInterval] {
        frames.map { ($0.frameDuration * 100).rounded() / 100 }
    }

    private static func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.000_001
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

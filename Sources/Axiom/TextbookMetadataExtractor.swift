import CryptoKit
import Foundation
import PDFKit

actor TextbookMetadataExtractor {
    func extract(textbookID: Int64, url: URL, store: TextbookStore) async {
        let started = ContinuousClock.now
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            guard let document = PDFDocument(url: url) else {
                throw TextbookStoreError.database("PDFKit could not open \(url.lastPathComponent).")
            }
            let fingerprint = try fileFingerprint(url)
            try await store.beginExtraction(
                textbookID: textbookID,
                fingerprint: fingerprint,
                pageCount: document.pageCount
            )

            for pageIndex in 0..<document.pageCount {
                let pageStarted = ContinuousClock.now
                let text = document.page(at: pageIndex)?.string ?? ""
                try await store.saveExtractedPage(textbookID: textbookID, pageIndex: pageIndex, text: text)
                AxiomLogger.info(
                    "Local metadata extracted. textbookID=\(textbookID), page=\(pageIndex + 1), characters=\(text.count), durationMs=\(AxiomLogger.durationMilliseconds(since: pageStarted))"
                )
            }
            try await store.finishExtraction(textbookID: textbookID)
            AxiomLogger.info(
                "Local textbook extraction complete. textbookID=\(textbookID), pages=\(document.pageCount), durationMs=\(AxiomLogger.durationMilliseconds(since: started)), aiRequests=0"
            )
        } catch {
            try? await store.failExtraction(textbookID: textbookID, error: error.localizedDescription)
            AxiomLogger.error("Local textbook extraction failed. textbookID=\(textbookID), error=\(error.localizedDescription)")
        }
    }

    private func fileFingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

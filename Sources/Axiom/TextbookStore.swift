import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum TextbookStoreError: LocalizedError {
    case database(String)
    case missingPage

    var errorDescription: String? {
        switch self {
        case let .database(message): message
        case .missingPage: "The page metadata has not been extracted yet."
        }
    }
}

actor TextbookStore {
    private var database: OpaquePointer?

    init(databaseURL: URL? = nil) throws {
        let resolvedURL: URL
        if let databaseURL {
            resolvedURL = databaseURL
        } else {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport.appendingPathComponent("Axiom", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            resolvedURL = directory.appendingPathComponent("axiom.sqlite3")
        }

        guard sqlite3_open(resolvedURL.path, &database) == SQLITE_OK else {
            throw TextbookStoreError.database("Could not open metadata database at \(resolvedURL.path).")
        }
        try Self.execute("PRAGMA foreign_keys = ON;", database: database)
        try Self.execute("PRAGMA journal_mode = WAL;", database: database)
        try Self.migrate(database: database)
        AxiomLogger.info("Metadata database ready. path=\(resolvedURL.path)")
    }

    func registerTextbook(url: URL, bookmark: Data?) throws -> TextbookSummary {
        let sql = """
        INSERT INTO textbooks(path, display_name, bookmark, extraction_status, added_at)
        VALUES(?, ?, ?, 'extracting', ?)
        ON CONFLICT(path) DO UPDATE SET
            display_name = excluded.display_name,
            bookmark = COALESCE(excluded.bookmark, textbooks.bookmark),
            error = NULL;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(url.path, at: 1, in: statement)
        bind(url.deletingPathExtension().lastPathComponent, at: 2, in: statement)
        bind(bookmark, at: 3, in: statement)
        bind(ISO8601DateFormatter().string(from: Date()), at: 4, in: statement)
        try stepDone(statement)
        guard let textbook = try textbook(path: url.path) else {
            throw TextbookStoreError.database("Textbook registration did not return a record.")
        }
        return textbook
    }

    func listTextbooks() throws -> [TextbookSummary] {
        let statement = try prepare("""
        SELECT id, path, display_name, bookmark, file_fingerprint, page_count,
               extracted_pages, extraction_status, error
        FROM textbooks
        ORDER BY added_at DESC;
        """)
        defer { sqlite3_finalize(statement) }
        var textbooks: [TextbookSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            textbooks.append(readTextbook(statement))
        }
        return textbooks
    }

    func textbook(id: Int64) throws -> TextbookSummary? {
        let statement = try prepare("""
        SELECT id, path, display_name, bookmark, file_fingerprint, page_count,
               extracted_pages, extraction_status, error
        FROM textbooks WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readTextbook(statement)
    }

    func updateReference(id: Int64, url: URL, bookmark: Data?) throws {
        let statement = try prepare("""
        UPDATE textbooks
        SET path = ?, display_name = ?, bookmark = ?, extraction_status = 'extracting', error = NULL
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(url.path, at: 1, in: statement)
        bind(url.deletingPathExtension().lastPathComponent, at: 2, in: statement)
        bind(bookmark, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, id)
        try stepDone(statement)
    }

    func beginExtraction(textbookID: Int64, fingerprint: String, pageCount: Int) throws {
        let existing = try textbook(id: textbookID)
        let changed = existing?.fileFingerprint.isEmpty == false && existing?.fileFingerprint != fingerprint
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            if changed {
                for sql in [
                    "DELETE FROM concept_occurrences WHERE concept_id IN (SELECT id FROM concepts WHERE textbook_id = ?);",
                    "DELETE FROM concepts WHERE textbook_id = ?;",
                    "DELETE FROM highlights WHERE textbook_id = ?;",
                    "DELETE FROM analysis_jobs WHERE textbook_id = ?;",
                    "DELETE FROM pages WHERE textbook_id = ?;"
                ] {
                    let delete = try prepare(sql)
                    sqlite3_bind_int64(delete, 1, textbookID)
                    try stepDone(delete)
                    sqlite3_finalize(delete)
                }
            }
            let update = try prepare("""
            UPDATE textbooks
            SET file_fingerprint = ?, page_count = ?, extracted_pages = 0,
                extraction_status = 'extracting', error = NULL
            WHERE id = ?;
            """)
            bind(fingerprint, at: 1, in: update)
            sqlite3_bind_int(update, 2, Int32(pageCount))
            sqlite3_bind_int64(update, 3, textbookID)
            try stepDone(update)
            sqlite3_finalize(update)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func saveExtractedPage(textbookID: Int64, pageIndex: Int, text: String) throws {
        let fingerprint = TextFingerprint.make(text)
        let status = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "needs_ocr" : "ready"
        if let existing = try page(textbookID: textbookID, pageIndex: pageIndex),
           existing.fingerprint != fingerprint {
            let delete = try prepare("DELETE FROM highlights WHERE textbook_id = ? AND page_index = ?;")
            sqlite3_bind_int64(delete, 1, textbookID)
            sqlite3_bind_int(delete, 2, Int32(pageIndex))
            try stepDone(delete)
            sqlite3_finalize(delete)
            try execute("DELETE FROM concepts WHERE id NOT IN (SELECT DISTINCT concept_id FROM concept_occurrences);")
        }
        let statement = try prepare("""
        INSERT INTO pages(textbook_id, page_index, text, text_fingerprint, extraction_status, analysis_status)
        VALUES(?, ?, ?, ?, ?, 'not_analyzed')
        ON CONFLICT(textbook_id, page_index) DO UPDATE SET
            text = excluded.text,
            extraction_status = excluded.extraction_status,
            analysis_status = CASE
                WHEN pages.text_fingerprint = excluded.text_fingerprint THEN pages.analysis_status
                ELSE 'not_analyzed'
            END,
            analysis_provider = CASE WHEN pages.text_fingerprint = excluded.text_fingerprint THEN pages.analysis_provider ELSE NULL END,
            analysis_model = CASE WHEN pages.text_fingerprint = excluded.text_fingerprint THEN pages.analysis_model ELSE NULL END,
            prompt_version = CASE WHEN pages.text_fingerprint = excluded.text_fingerprint THEN pages.prompt_version ELSE NULL END,
            analysis_error = CASE WHEN pages.text_fingerprint = excluded.text_fingerprint THEN pages.analysis_error ELSE NULL END,
            text_fingerprint = excluded.text_fingerprint;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        bind(text, at: 3, in: statement)
        bind(fingerprint, at: 4, in: statement)
        bind(status, at: 5, in: statement)
        try stepDone(statement)

        let update = try prepare("""
        UPDATE textbooks
        SET extracted_pages = (SELECT COUNT(*) FROM pages WHERE textbook_id = ?)
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(update) }
        sqlite3_bind_int64(update, 1, textbookID)
        sqlite3_bind_int64(update, 2, textbookID)
        try stepDone(update)
    }

    func finishExtraction(textbookID: Int64) throws {
        let statement = try prepare("UPDATE textbooks SET extraction_status = 'ready', error = NULL WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        try stepDone(statement)
    }

    func failExtraction(textbookID: Int64, error: String) throws {
        let statement = try prepare("UPDATE textbooks SET extraction_status = 'failed', error = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(error, at: 1, in: statement)
        sqlite3_bind_int64(statement, 2, textbookID)
        try stepDone(statement)
    }

    func page(textbookID: Int64, pageIndex: Int) throws -> StoredPage? {
        let statement = try prepare("""
        SELECT text, text_fingerprint, extraction_status, analysis_status, analysis_error
        FROM pages WHERE textbook_id = ? AND page_index = ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return StoredPage(
            textbookID: textbookID,
            pageIndex: pageIndex,
            text: string(statement, column: 0),
            fingerprint: string(statement, column: 1),
            extractionStatus: string(statement, column: 2),
            analysisStatus: string(statement, column: 3),
            analysisError: optionalString(statement, column: 4)
        )
    }

    func cachedAnalysis(textbookID: Int64, pageIndex: Int, identity: AnalysisIdentity) throws -> CachedPageAnalysis {
        let statement = try prepare("""
        SELECT analysis_status, analysis_provider, analysis_model, prompt_version, analysis_error
        FROM pages WHERE textbook_id = ? AND page_index = ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        guard sqlite3_step(statement) == SQLITE_ROW else { return .missing }

        let status = string(statement, column: 0)
        let matchesIdentity = optionalString(statement, column: 1) == identity.provider
            && optionalString(statement, column: 2) == identity.model
            && optionalString(statement, column: 3) == identity.promptVersion
        guard matchesIdentity else { return .missing }

        switch status {
        case "ready": return .ready(try highlights(textbookID: textbookID, pageIndex: pageIndex))
        case "analyzing": return .analyzing
        case "failed": return .failed(optionalString(statement, column: 4) ?? "Unknown analysis error")
        default: return .missing
        }
    }

    func markAnalyzing(textbookID: Int64, pageIndex: Int, identity: AnalysisIdentity) throws {
        let statement = try prepare("""
        UPDATE pages SET analysis_status = 'analyzing', analysis_provider = ?, analysis_model = ?,
            prompt_version = ?, analysis_error = NULL
        WHERE textbook_id = ? AND page_index = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(identity.provider, at: 1, in: statement)
        bind(identity.model, at: 2, in: statement)
        bind(identity.promptVersion, at: 3, in: statement)
        sqlite3_bind_int64(statement, 4, textbookID)
        sqlite3_bind_int(statement, 5, Int32(pageIndex))
        try stepDone(statement)
        try upsertJob(textbookID: textbookID, pageIndex: pageIndex, status: "processing", error: nil)
    }

    func saveAnalysis(
        textbookID: Int64,
        pageIndex: Int,
        identity: AnalysisIdentity,
        passages: [ImportantPassage]
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let delete = try prepare("DELETE FROM highlights WHERE textbook_id = ? AND page_index = ?;")
            sqlite3_bind_int64(delete, 1, textbookID)
            sqlite3_bind_int(delete, 2, Int32(pageIndex))
            try stepDone(delete)
            sqlite3_finalize(delete)

            for passage in passages {
                let insert = try prepare("""
                INSERT INTO highlights(textbook_id, page_index, exact_text, range_location, range_length,
                    kind, explanation, importance, concepts_json)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
                sqlite3_bind_int64(insert, 1, textbookID)
                sqlite3_bind_int(insert, 2, Int32(pageIndex))
                bind(passage.sentence, at: 3, in: insert)
                sqlite3_bind_int(insert, 4, Int32(passage.range.location))
                sqlite3_bind_int(insert, 5, Int32(passage.range.length))
                bind(passage.kind, at: 6, in: insert)
                bind(passage.explanation, at: 7, in: insert)
                sqlite3_bind_int(insert, 8, Int32(passage.score))
                bind(Self.encodeConcepts(passage.concepts), at: 9, in: insert)
                try stepDone(insert)
                let highlightID = sqlite3_last_insert_rowid(database)
                sqlite3_finalize(insert)
                try saveConcepts(passage.concepts, textbookID: textbookID, pageIndex: pageIndex, highlightID: highlightID)
            }

            try execute("DELETE FROM concepts WHERE id NOT IN (SELECT DISTINCT concept_id FROM concept_occurrences);")
            try execute("""
            UPDATE concepts
            SET first_page_index = (
                SELECT MIN(page_index) FROM concept_occurrences
                WHERE concept_occurrences.concept_id = concepts.id
            )
            WHERE textbook_id = \(textbookID);
            """)

            let update = try prepare("""
            UPDATE pages SET analysis_status = 'ready', analysis_provider = ?, analysis_model = ?,
                prompt_version = ?, analysis_error = NULL
            WHERE textbook_id = ? AND page_index = ?;
            """)
            bind(identity.provider, at: 1, in: update)
            bind(identity.model, at: 2, in: update)
            bind(identity.promptVersion, at: 3, in: update)
            sqlite3_bind_int64(update, 4, textbookID)
            sqlite3_bind_int(update, 5, Int32(pageIndex))
            try stepDone(update)
            sqlite3_finalize(update)
            try upsertJob(textbookID: textbookID, pageIndex: pageIndex, status: "complete", error: nil)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func failAnalysis(textbookID: Int64, pageIndex: Int, identity: AnalysisIdentity, error: String) throws {
        let statement = try prepare("""
        UPDATE pages SET analysis_status = 'failed', analysis_provider = ?, analysis_model = ?,
            prompt_version = ?, analysis_error = ?
        WHERE textbook_id = ? AND page_index = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(identity.provider, at: 1, in: statement)
        bind(identity.model, at: 2, in: statement)
        bind(identity.promptVersion, at: 3, in: statement)
        bind(error, at: 4, in: statement)
        sqlite3_bind_int64(statement, 5, textbookID)
        sqlite3_bind_int(statement, 6, Int32(pageIndex))
        try stepDone(statement)
        try upsertJob(textbookID: textbookID, pageIndex: pageIndex, status: "failed", error: error)
    }

    func clearAnalysis(textbookID: Int64, pageIndex: Int) throws {
        let statement = try prepare("""
        UPDATE pages SET analysis_status = 'not_analyzed', analysis_provider = NULL,
            analysis_model = NULL, prompt_version = NULL, analysis_error = NULL
        WHERE textbook_id = ? AND page_index = ?;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        try stepDone(statement)
    }

    func removeTextbook(id: Int64) throws {
        let statement = try prepare("DELETE FROM textbooks WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        try stepDone(statement)
    }

    func resetInterruptedAnalysis() throws {
        try execute("""
        UPDATE pages SET analysis_status = 'not_analyzed', analysis_error = NULL
        WHERE analysis_status = 'analyzing';
        UPDATE analysis_jobs SET status = 'pending', error = NULL
        WHERE status = 'processing';
        """)
    }

    private func textbook(path: String) throws -> TextbookSummary? {
        let statement = try prepare("""
        SELECT id, path, display_name, bookmark, file_fingerprint, page_count,
               extracted_pages, extraction_status, error
        FROM textbooks WHERE path = ?;
        """)
        defer { sqlite3_finalize(statement) }
        bind(path, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readTextbook(statement)
    }

    private func highlights(textbookID: Int64, pageIndex: Int) throws -> [StoredHighlight] {
        let statement = try prepare("""
        SELECT exact_text, range_location, range_length, kind, explanation, importance, concepts_json
        FROM highlights WHERE textbook_id = ? AND page_index = ? ORDER BY id;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        var results: [StoredHighlight] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(StoredHighlight(
                pageIndex: pageIndex,
                exactText: string(statement, column: 0),
                location: Int(sqlite3_column_int(statement, 1)),
                length: Int(sqlite3_column_int(statement, 2)),
                kind: string(statement, column: 3),
                explanation: string(statement, column: 4),
                importance: Int(sqlite3_column_int(statement, 5)),
                concepts: Self.decodeConcepts(string(statement, column: 6))
            ))
        }
        return results
    }

    private func saveConcepts(_ concepts: [String], textbookID: Int64, pageIndex: Int, highlightID: Int64) throws {
        for concept in concepts {
            let canonical = concept.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            let normalized = canonical.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let insert = try prepare("""
            INSERT INTO concepts(textbook_id, canonical_name, normalized_name, first_page_index)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(textbook_id, normalized_name) DO UPDATE SET
                first_page_index = MIN(concepts.first_page_index, excluded.first_page_index);
            """)
            sqlite3_bind_int64(insert, 1, textbookID)
            bind(canonical, at: 2, in: insert)
            bind(normalized, at: 3, in: insert)
            sqlite3_bind_int(insert, 4, Int32(pageIndex))
            try stepDone(insert)
            sqlite3_finalize(insert)

            let occurrence = try prepare("""
            INSERT OR IGNORE INTO concept_occurrences(concept_id, highlight_id, page_index)
            SELECT id, ?, ? FROM concepts WHERE textbook_id = ? AND normalized_name = ?;
            """)
            sqlite3_bind_int64(occurrence, 1, highlightID)
            sqlite3_bind_int(occurrence, 2, Int32(pageIndex))
            sqlite3_bind_int64(occurrence, 3, textbookID)
            bind(normalized, at: 4, in: occurrence)
            try stepDone(occurrence)
            sqlite3_finalize(occurrence)
        }
    }

    private func upsertJob(textbookID: Int64, pageIndex: Int, status: String, error: String?) throws {
        let statement = try prepare("""
        INSERT INTO analysis_jobs(textbook_id, page_index, status, attempt_count, error, updated_at)
        VALUES(?, ?, ?, 1, ?, ?)
        ON CONFLICT(textbook_id, page_index) DO UPDATE SET
            status = excluded.status,
            attempt_count = CASE WHEN excluded.status = 'processing' THEN analysis_jobs.attempt_count + 1 ELSE analysis_jobs.attempt_count END,
            error = excluded.error,
            updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, textbookID)
        sqlite3_bind_int(statement, 2, Int32(pageIndex))
        bind(status, at: 3, in: statement)
        bind(error, at: 4, in: statement)
        bind(ISO8601DateFormatter().string(from: Date()), at: 5, in: statement)
        try stepDone(statement)
    }

    private static func migrate(database: OpaquePointer?) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS textbooks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            bookmark BLOB,
            file_fingerprint TEXT NOT NULL DEFAULT '',
            page_count INTEGER NOT NULL DEFAULT 0,
            extracted_pages INTEGER NOT NULL DEFAULT 0,
            extraction_status TEXT NOT NULL DEFAULT 'extracting',
            error TEXT,
            added_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS pages(
            textbook_id INTEGER NOT NULL REFERENCES textbooks(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            text TEXT NOT NULL,
            text_fingerprint TEXT NOT NULL,
            extraction_status TEXT NOT NULL,
            analysis_status TEXT NOT NULL DEFAULT 'not_analyzed',
            analysis_provider TEXT,
            analysis_model TEXT,
            prompt_version TEXT,
            analysis_error TEXT,
            PRIMARY KEY(textbook_id, page_index)
        );
        CREATE TABLE IF NOT EXISTS highlights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            textbook_id INTEGER NOT NULL REFERENCES textbooks(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            exact_text TEXT NOT NULL,
            range_location INTEGER NOT NULL,
            range_length INTEGER NOT NULL,
            kind TEXT NOT NULL,
            explanation TEXT NOT NULL,
            importance INTEGER NOT NULL,
            concepts_json TEXT NOT NULL DEFAULT '[]'
        );
        CREATE INDEX IF NOT EXISTS highlights_page ON highlights(textbook_id, page_index);
        CREATE TABLE IF NOT EXISTS concepts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            textbook_id INTEGER NOT NULL REFERENCES textbooks(id) ON DELETE CASCADE,
            canonical_name TEXT NOT NULL,
            normalized_name TEXT NOT NULL,
            first_page_index INTEGER NOT NULL,
            UNIQUE(textbook_id, normalized_name)
        );
        CREATE TABLE IF NOT EXISTS concept_occurrences(
            concept_id INTEGER NOT NULL REFERENCES concepts(id) ON DELETE CASCADE,
            highlight_id INTEGER NOT NULL REFERENCES highlights(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            UNIQUE(concept_id, highlight_id)
        );
        CREATE TABLE IF NOT EXISTS analysis_jobs(
            textbook_id INTEGER NOT NULL REFERENCES textbooks(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            status TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            error TEXT,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(textbook_id, page_index)
        );
        """, database: database)
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, database: database)
    }

    private static func execute(_ sql: String, database: OpaquePointer?) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorPointer)
            throw TextbookStoreError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TextbookStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TextbookStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ value: Data?, at index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
        }
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalString(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : string(statement, column: column)
    }

    private func data(_ statement: OpaquePointer, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func readTextbook(_ statement: OpaquePointer) -> TextbookSummary {
        TextbookSummary(
            id: sqlite3_column_int64(statement, 0),
            path: string(statement, column: 1),
            displayName: string(statement, column: 2),
            bookmark: data(statement, column: 3),
            fileFingerprint: string(statement, column: 4),
            pageCount: Int(sqlite3_column_int(statement, 5)),
            extractedPages: Int(sqlite3_column_int(statement, 6)),
            extractionStatus: string(statement, column: 7),
            error: optionalString(statement, column: 8)
        )
    }

    private static func encodeConcepts(_ concepts: [String]) -> String {
        guard let data = try? JSONEncoder().encode(concepts) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeConcepts(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}

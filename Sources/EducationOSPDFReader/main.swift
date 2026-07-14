import AppKit
import PDFKit

struct ImportantPassage {
    let pageIndex: Int
    let sentence: String
    let range: NSRange
    let kind: String
    let explanation: String
    let score: Int
}

struct PageText {
    let pageIndex: Int
    let text: String
}

struct MathHighlightCandidate: Decodable {
    let page_index: Int
    let exact_text: String
    let kind: String
    let explanation: String
    let importance: Int
}

struct MathHighlightResponse: Decodable {
    let highlights: [MathHighlightCandidate]
}

enum RemoteAnalyzerError: Error {
    case missingAPIKey
    case invalidURL
    case invalidResponse(statusCode: Int, body: String)
    case missingOutputText(body: String)
    case outputDecodeFailed(String)
}

extension RemoteAnalyzerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Missing API key."
        case .invalidURL:
            "Invalid API URL."
        case let .invalidResponse(statusCode, body):
            "HTTP \(statusCode): \(body)"
        case let .missingOutputText(body):
            "Could not find output text in response: \(body)"
        case let .outputDecodeFailed(message):
            "Could not decode model JSON: \(message)"
        }
    }
}

enum MathPilotLogger {
    private static let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("mathpilot.log")

    static var path: String {
        logURL.path
    }

    static func info(_ message: String) {
        write(level: "INFO", message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message)
    }

    static func redact(_ value: String) -> String {
        guard value.count > 8 else {
            return "<redacted>"
        }

        return "\(value.prefix(4))...\(value.suffix(4))"
    }

    static func snippet(_ data: Data, limit: Int = 2_000) -> String {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
        return snippet(text, limit: limit)
    }

    static func snippet(_ text: String, limit: Int = 2_000) -> String {
        String(text.prefix(limit))
    }

    static func writeDebugFile(name: String, data: Data) {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)

        do {
            try data.write(to: url)
            info("Wrote debug response file: \(url.path)")
        } catch let writeError {
            self.error("Failed to write debug response file \(url.path): \(writeError)")
        }
    }

    private static func write(level: String, _ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        print(line, terminator: "")

        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

enum Dotenv {
    static func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for (key, value) in valuesFromDotenv() where environment[key] == nil {
            environment[key] = value
        }

        return environment
    }

    private static func valuesFromDotenv() -> [String: String] {
        let dotenvURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env")

        guard let contents = try? String(contentsOf: dotenvURL, encoding: .utf8) else {
            return [:]
        }

        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               value.first == "\"",
               value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }

            values[key] = value
        }

        return values
    }
}

enum MathAnalysisPrompt {
    static let instructions = """
    You are MathPilot, an AI reading assistant for mathematics lecture notes.
    Identify only text spans that should be visually highlighted for a student reading the PDF.
    Prefer definitions, theorems, lemmas, corollaries, equations, notation, and central concepts.
    exact_text must be copied exactly from the provided page text and should be short enough to highlight directly.
    Do not solve exercises. Do not include generic prose unless it names a mathematical concept.
    """

    static func input(from pages: [PageText]) -> String {
        let maxCharacters = 22_000
        var usedCharacters = 0
        var sections: [String] = []

        for page in pages {
            let trimmedText = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                continue
            }

            let remaining = maxCharacters - usedCharacters
            guard remaining > 0 else {
                break
            }

            let pageText = String(trimmedText.prefix(remaining))
            usedCharacters += pageText.count
            sections.append("PAGE_INDEX: \(page.pageIndex)\nTEXT:\n\(pageText)")
        }

        return sections.joined(separator: "\n\n---\n\n")
    }

    static func mapHighlights(_ highlights: [MathHighlightCandidate], onto pages: [PageText]) -> [ImportantPassage] {
        highlights.compactMap { highlight in
            guard let page = pages.first(where: { $0.pageIndex == highlight.page_index }) else {
                MathPilotLogger.error("Highlight candidate references missing page. pageIndex=\(highlight.page_index), text=\(MathPilotLogger.snippet(highlight.exact_text, limit: 160))")
                return nil
            }

            guard let range = rangeForHighlight(highlight.exact_text, in: page.text) else {
                MathPilotLogger.error("Could not map highlight text back to PDF page. pageIndex=\(highlight.page_index), kind=\(highlight.kind), text=\(MathPilotLogger.snippet(highlight.exact_text, limit: 240))")
                return nil
            }

            return ImportantPassage(
                pageIndex: highlight.page_index,
                sentence: highlight.exact_text,
                range: range,
                kind: highlight.kind,
                explanation: highlight.explanation,
                score: highlight.importance
            )
        }
    }

    private static func rangeForHighlight(_ highlightText: String, in pageText: String) -> NSRange? {
        let nsPageText = pageText as NSString
        let directRange = nsPageText.range(of: highlightText, options: [.caseInsensitive])
        if directRange.location != NSNotFound {
            return directRange
        }

        let words = highlightText
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        guard words.count >= 4 else {
            return nil
        }

        let phraseWords = Array(words.prefix(12))
        let pattern = phraseWords
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: #"[\s\p{P}]*"#)

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: nsPageText.length)
        return regex.firstMatch(in: pageText, range: fullRange)?.range
    }
}

final class ImportanceAnalyzer {
    private let cuePhrases = [
        "important", "key", "therefore", "in conclusion", "summary",
        "must", "should", "because", "result", "finding", "evidence",
        "definition", "principle", "remember", "critical", "main"
    ]

    func passages(in document: PDFDocument, limit: Int = 18) -> [ImportantPassage] {
        var candidates: [ImportantPassage] = []

        for pageIndex in 0..<document.pageCount {
            guard let text = document.page(at: pageIndex)?.string else {
                continue
            }

            for candidate in sentences(from: text) {
                let sentence = candidate.sentence
                let score = scoreSentence(sentence)
                if score >= 5 {
                    candidates.append(ImportantPassage(
                        pageIndex: pageIndex,
                        sentence: sentence,
                        range: candidate.range,
                        kind: "important_text",
                        explanation: "Selected by the local fallback heuristic.",
                        score: score
                    ))
                }
            }
        }

        return Array(candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.sentence.count > rhs.sentence.count
            }
            return lhs.score > rhs.score
        }.prefix(limit))
    }

    private func sentences(from text: String) -> [(sentence: String, range: NSRange)] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var results: [(sentence: String, range: NSRange)] = []

        (text as NSString).enumerateSubstrings(in: fullRange, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let rawSentence = (text as NSString).substring(with: range)
            let normalizedSentence = rawSentence
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedSentence.count >= 70 && normalizedSentence.count <= 360 {
                results.append((sentence: normalizedSentence, range: range))
            }
        }

        return results
    }

    private func scoreSentence(_ sentence: String) -> Int {
        let lowercased = sentence.lowercased()
        var score = 0

        for phrase in cuePhrases where lowercased.contains(phrase) {
            score += 3
        }

        if sentence.contains(":") || sentence.contains(";") {
            score += 2
        }

        let wordCount = sentence.split(separator: " ").count
        if (16...38).contains(wordCount) {
            score += 3
        } else if (39...55).contains(wordCount) {
            score += 1
        }

        let capitalizedTerms = sentence.split(separator: " ").filter { token in
            guard let first = token.first else { return false }
            return first.isUppercase && token.count > 3
        }
        score += min(capitalizedTerms.count, 4)

        return score
    }
}

@MainActor
final class OpenAIMathAnalyzer {
    private let apiKey: String?
    private let model: String

    var isConfigured: Bool {
        apiKey?.isEmpty == false
    }

    init(environment: [String: String] = Dotenv.mergedEnvironment()) {
        apiKey = environment["OPENAI_API_KEY"]
        model = environment["OPENAI_MODEL"] ?? "gpt-5.2"
    }

    func passages(from pages: [PageText], limit: Int = 16) async throws -> [ImportantPassage] {
        guard let apiKey, !apiKey.isEmpty else {
            MathPilotLogger.error("OpenAI analyzer selected but OPENAI_API_KEY is missing.")
            throw RemoteAnalyzerError.missingAPIKey
        }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw RemoteAnalyzerError.invalidURL
        }

        let input = MathAnalysisPrompt.input(from: pages)
        MathPilotLogger.info("OpenAI request starting. model=\(model), pages=\(pages.count), inputCharacters=\(input.count), key=\(MathPilotLogger.redact(apiKey))")
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "highlights": [
                    "type": "array",
                    "maxItems": limit,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "page_index": ["type": "integer"],
                            "exact_text": ["type": "string"],
                            "kind": [
                                "type": "string",
                                "enum": ["definition", "theorem", "lemma", "corollary", "equation", "notation", "concept"]
                            ],
                            "explanation": ["type": "string"],
                            "importance": ["type": "integer", "minimum": 1, "maximum": 10]
                        ],
                        "required": ["page_index", "exact_text", "kind", "explanation", "importance"]
                    ]
                ]
            ],
            "required": ["highlights"]
        ]

        let body: [String: Any] = [
            "model": model,
            "instructions": MathAnalysisPrompt.instructions,
            "input": input,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "mathpilot_highlights",
                    "schema": schema,
                    "strict": true
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = MathPilotLogger.snippet(data)
            MathPilotLogger.error("OpenAI request failed. status=\(statusCode), body=\(body)")
            throw RemoteAnalyzerError.invalidResponse(statusCode: statusCode, body: body)
        }
        MathPilotLogger.info("OpenAI request succeeded. responseBytes=\(data.count)")

        let outputText = try extractOutputText(from: data)
        MathPilotLogger.info("OpenAI output text received. characters=\(outputText.count), snippet=\(MathPilotLogger.snippet(outputText, limit: 500))")
        do {
            let decoded = try JSONDecoder().decode(MathHighlightResponse.self, from: Data(outputText.utf8))
            let passages = MathAnalysisPrompt.mapHighlights(decoded.highlights, onto: pages)
            MathPilotLogger.info("OpenAI decoded highlights=\(decoded.highlights.count), mappedPassages=\(passages.count)")
            return passages
        } catch {
            MathPilotLogger.error("OpenAI JSON decode failed. error=\(error), output=\(MathPilotLogger.snippet(outputText))")
            throw RemoteAnalyzerError.outputDecodeFailed(String(describing: error))
        }
    }

    private func extractOutputText(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let output = dictionary["output"] as? [[String: Any]] else {
            throw RemoteAnalyzerError.missingOutputText(body: MathPilotLogger.snippet(data))
        }

        for item in output {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }

            for contentItem in content {
                if let text = contentItem["text"] as? String {
                    return text
                }
            }
        }

        throw RemoteAnalyzerError.missingOutputText(body: MathPilotLogger.snippet(data))
    }
}

@MainActor
final class GeminiMathAnalyzer {
    private let apiKey: String?
    private let model: String

    var isConfigured: Bool {
        apiKey?.isEmpty == false
    }

    init(environment: [String: String] = Dotenv.mergedEnvironment()) {
        apiKey = environment["GEMINI_API_KEY"]
        model = environment["GEMINI_MODEL"] ?? "gemini-3.5-flash"
    }

    func passages(from pages: [PageText], limit: Int = 16) async throws -> [ImportantPassage] {
        guard let apiKey, !apiKey.isEmpty else {
            MathPilotLogger.error("Gemini analyzer selected but GEMINI_API_KEY is missing.")
            throw RemoteAnalyzerError.missingAPIKey
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw RemoteAnalyzerError.invalidURL
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "highlights": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "page_index": ["type": "integer"],
                            "exact_text": ["type": "string"],
                            "kind": [
                                "type": "string",
                                "enum": ["definition", "theorem", "lemma", "corollary", "equation", "notation", "concept"]
                            ],
                            "explanation": ["type": "string"],
                            "importance": ["type": "integer"]
                        ],
                        "required": ["page_index", "exact_text", "kind", "explanation", "importance"]
                    ]
                ]
            ],
            "required": ["highlights"]
        ]

        let input = """
        \(MathAnalysisPrompt.instructions)

        Return at most \(limit) highlights.

        \(MathAnalysisPrompt.input(from: pages))
        """
        MathPilotLogger.info("Gemini request starting. model=\(model), endpoint=\(url.absoluteString), pages=\(pages.count), inputCharacters=\(input.count), key=\(MathPilotLogger.redact(apiKey))")

        let body: [String: Any] = [
            "model": model,
            "input": input,
            "response_format": [
                "type": "text",
                "mime_type": "application/json",
                "schema": schema
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = MathPilotLogger.snippet(data)
            MathPilotLogger.error("Gemini request failed. status=\(statusCode), body=\(body)")
            throw RemoteAnalyzerError.invalidResponse(statusCode: statusCode, body: body)
        }
        MathPilotLogger.info("Gemini request succeeded. responseBytes=\(data.count), responseSnippet=\(MathPilotLogger.snippet(data, limit: 500))")
        MathPilotLogger.writeDebugFile(name: "mathpilot-last-gemini-response.json", data: data)

        let outputText = try extractOutputText(from: data)
        MathPilotLogger.info("Gemini output text received. characters=\(outputText.count), snippet=\(MathPilotLogger.snippet(outputText, limit: 500))")
        do {
            let decoded = try JSONDecoder().decode(MathHighlightResponse.self, from: Data(outputText.utf8))
            let passages = MathAnalysisPrompt.mapHighlights(decoded.highlights, onto: pages)
            MathPilotLogger.info("Gemini decoded highlights=\(decoded.highlights.count), mappedPassages=\(passages.count)")
            return passages
        } catch {
            MathPilotLogger.error("Gemini JSON decode failed. error=\(error), output=\(MathPilotLogger.snippet(outputText))")
            throw RemoteAnalyzerError.outputDecodeFailed(String(describing: error))
        }
    }

    private func extractOutputText(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw RemoteAnalyzerError.missingOutputText(body: MathPilotLogger.snippet(data))
        }

        if let outputText = dictionary["output_text"] as? String {
            return cleanedJSONText(outputText)
        }

        if let output = dictionary["output"] as? [[String: Any]] {
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else {
                    continue
                }
                for contentItem in content {
                    if let text = contentItem["text"] as? String {
                        return cleanedJSONText(text)
                    }
                }
            }
        }

        if let candidates = dictionary["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                if let content = candidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String {
                            return cleanedJSONText(text)
                        }
                    }
                }
            }
        }

        if let nestedText = firstJSONStringContainingHighlights(in: object) {
            return cleanedJSONText(nestedText)
        }

        MathPilotLogger.error("Gemini response had no recognized output text. topLevelKeys=\(Array(dictionary.keys).sorted())")
        throw RemoteAnalyzerError.missingOutputText(body: MathPilotLogger.snippet(data))
    }

    private func firstJSONStringContainingHighlights(in value: Any) -> String? {
        if let string = value as? String {
            return string.contains("\"highlights\"") || string.contains("highlights") ? string : nil
        }

        if let array = value as? [Any] {
            for item in array {
                if let found = firstJSONStringContainingHighlights(in: item) {
                    return found
                }
            }
            return nil
        }

        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if let found = firstJSONStringContainingHighlights(in: dictionary[key] as Any) {
                    return found
                }
            }
        }

        return nil
    }

    private func cleanedJSONText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        return cleaned
    }
}

@MainActor
final class ConfiguredMathAnalyzer {
    private enum Provider {
        case gemini
        case openai
    }

    private let provider: Provider
    private let geminiAnalyzer: GeminiMathAnalyzer
    private let openAIAnalyzer: OpenAIMathAnalyzer

    var providerName: String {
        switch provider {
        case .gemini: "Gemini"
        case .openai: "OpenAI"
        }
    }

    var isConfigured: Bool {
        switch provider {
        case .gemini: geminiAnalyzer.isConfigured
        case .openai: openAIAnalyzer.isConfigured
        }
    }

    var missingConfigurationMessage: String {
        switch provider {
        case .gemini: "GEMINI_API_KEY is not set. MathPilot will use the local fallback heuristic."
        case .openai: "OPENAI_API_KEY is not set. MathPilot will use the local fallback heuristic."
        }
    }

    init(environment: [String: String] = Dotenv.mergedEnvironment()) {
        geminiAnalyzer = GeminiMathAnalyzer(environment: environment)
        openAIAnalyzer = OpenAIMathAnalyzer(environment: environment)

        let providerValue = environment["AI_PROVIDER"]?.lowercased()
        if providerValue == "openai" {
            provider = .openai
        } else if providerValue == "gemini" {
            provider = .gemini
        } else if geminiAnalyzer.isConfigured {
            provider = .gemini
        } else if openAIAnalyzer.isConfigured {
            provider = .openai
        } else {
            provider = .gemini
        }

        MathPilotLogger.info("Configured AI provider=\(providerName), configured=\(isConfigured), logPath=\(MathPilotLogger.path)")
    }

    func passages(from pages: [PageText]) async throws -> [ImportantPassage] {
        switch provider {
        case .gemini:
            try await geminiAnalyzer.passages(from: pages)
        case .openai:
            try await openAIAnalyzer.passages(from: pages)
        }
    }
}

@MainActor
final class ReaderViewController: NSViewController {
    private let pdfView = PDFView()
    private let sidebarView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "Open a PDF to begin.")
    private let analyzer = ImportanceAnalyzer()
    private let aiAnalyzer = ConfiguredMathAnalyzer()
    private var currentDocument: PDFDocument?
    private var analysisTask: Task<Void, Never>?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let toolbar = makeToolbar()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        let readerPane = NSView()
        readerPane.translatesAutoresizingMaskIntoConstraints = false
        readerPane.wantsLayer = true
        readerPane.layer?.backgroundColor = NSColor(calibratedWhite: 0.88, alpha: 1).cgColor
        readerPane.addSubview(pdfView)

        sidebarView.isEditable = false
        sidebarView.drawsBackground = true
        sidebarView.backgroundColor = NSColor.textBackgroundColor
        sidebarView.textContainerInset = NSSize(width: 14, height: 14)
        sidebarView.font = NSFont.systemFont(ofSize: 13)

        let sidebarScrollView = NSScrollView()
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.documentView = sidebarView
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScrollView.wantsLayer = true
        sidebarScrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        sidebarScrollView.layer?.borderWidth = 1

        root.addSubview(toolbar)
        root.addSubview(readerPane)
        root.addSubview(sidebarScrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),

            readerPane.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            readerPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            readerPane.trailingAnchor.constraint(equalTo: sidebarScrollView.leadingAnchor),
            readerPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            readerPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),

            pdfView.topAnchor.constraint(equalTo: readerPane.topAnchor, constant: 12),
            pdfView.leadingAnchor.constraint(equalTo: readerPane.leadingAnchor, constant: 12),
            pdfView.trailingAnchor.constraint(equalTo: readerPane.trailingAnchor, constant: -12),
            pdfView.bottomAnchor.constraint(equalTo: readerPane.bottomAnchor, constant: -12),

            sidebarScrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sidebarScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            sidebarScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarScrollView.widthAnchor.constraint(equalToConstant: 360)
        ])

        view = root
    }

    func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        loadPDF(at: url)
    }

    private func loadPDF(at url: URL) {
        guard let document = PDFDocument(url: url) else {
            statusLabel.stringValue = "Could not open \(url.lastPathComponent)."
            MathPilotLogger.error("Failed to open PDF at path=\(url.path)")
            return
        }

        MathPilotLogger.info("Loaded PDF file=\(url.lastPathComponent), pages=\(document.pageCount)")
        analysisTask?.cancel()
        currentDocument = document
        pdfView.document = document
        if let firstPage = document.page(at: 0) {
            pdfView.go(to: firstPage)
        }
        pdfView.autoScales = true
        pdfView.needsLayout = true
        statusLabel.stringValue = "\(url.lastPathComponent) - \(document.pageCount) page(s)"
        clearExistingPrototypeAnnotations(in: document)
        emphasizeImportantText()
    }

    private func emphasizeImportantText() {
        guard let document = currentDocument else {
            return
        }

        analysisTask?.cancel()
        clearExistingPrototypeAnnotations(in: document)
        renderSidebar(
            for: [],
            highlightCount: 0,
            mode: "Analyzing",
            note: aiAnalyzer.isConfigured
                ? "MathPilot is asking \(aiAnalyzer.providerName) to identify definitions, theorems, equations, notation, and concepts."
                : aiAnalyzer.missingConfigurationMessage
        )
        statusLabel.stringValue = aiAnalyzer.isConfigured
            ? "\(aiAnalyzer.providerName) analysis running..."
            : "Using local fallback analysis..."

        analysisTask = Task { [weak self, weak document] in
            guard let self, let document else {
                return
            }

            await self.analyzeAndHighlight(document)
        }
    }

    private func analyzeAndHighlight(_ document: PDFDocument) async {
        let pages = extractPageText(from: document)
        let totalCharacters = pages.reduce(0) { $0 + $1.text.count }
        MathPilotLogger.info("Starting analysis. provider=\(aiAnalyzer.providerName), configured=\(aiAnalyzer.isConfigured), pagesWithText=\(pages.count), extractedCharacters=\(totalCharacters)")
        var mode = aiAnalyzer.providerName
        var note = "\(aiAnalyzer.providerName) selected math-specific concepts from the PDF text."
        let passages: [ImportantPassage]

        if aiAnalyzer.isConfigured {
            do {
                passages = try await aiAnalyzer.passages(from: pages)
            } catch {
                mode = "Local fallback"
                note = "AI analysis failed, so MathPilot used the local fallback heuristic. Error: \(error)"
                MathPilotLogger.error("Remote analysis failed. provider=\(aiAnalyzer.providerName), error=\(error.localizedDescription)")
                passages = analyzer.passages(in: document)
            }
        } else {
            mode = "Local fallback"
            note = aiAnalyzer.missingConfigurationMessage
            MathPilotLogger.info("Remote analysis skipped. \(note)")
            passages = analyzer.passages(in: document)
        }

        guard !Task.isCancelled, currentDocument === document else {
            return
        }

        clearExistingPrototypeAnnotations(in: document)
        let highlightCount = addHighlights(for: passages, in: document)
        MathPilotLogger.info("Analysis complete. mode=\(mode), candidatePassages=\(passages.count), onPageHighlights=\(highlightCount)")
        renderSidebar(for: passages, highlightCount: highlightCount, mode: mode, note: note)

        if passages.isEmpty {
            statusLabel.stringValue = "No highlight candidates found."
        } else {
            statusLabel.stringValue = "\(mode): added \(highlightCount) yellow on-page highlight(s)."
        }
    }

    private func extractPageText(from document: PDFDocument) -> [PageText] {
        (0..<document.pageCount).compactMap { pageIndex in
            guard let text = document.page(at: pageIndex)?.string else {
                return nil
            }
            return PageText(pageIndex: pageIndex, text: text)
        }
    }

    private func addHighlights(for passages: [ImportantPassage], in document: PDFDocument) -> Int {
        var highlightCount = 0

        for passage in passages {
            guard let page = document.page(at: passage.pageIndex),
                  let selection = page.selection(for: passage.range) else {
                continue
            }

            for lineSelection in selection.selectionsByLine() {
                let bounds = lineSelection.bounds(for: page).insetBy(dx: -2, dy: -1)
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.55)
                annotation.userName = "EducationOSAutoHighlight"
                page.addAnnotation(annotation)
                highlightCount += 1
            }
        }

        pdfView.setNeedsDisplay(pdfView.bounds)
        return highlightCount
    }

    private func clearExistingPrototypeAnnotations(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }

            for annotation in page.annotations where annotation.userName == "EducationOSAutoHighlight" {
                page.removeAnnotation(annotation)
            }
        }
    }

    private func renderSidebar(for passages: [ImportantPassage], highlightCount: Int, mode: String, note: String) {
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(
            string: "Highlight candidates\n\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 16),
                .foregroundColor: NSColor.labelColor
            ]
        ))
        content.append(NSAttributedString(
            string: "Mode: \(mode)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        content.append(NSAttributedString(
            string: "On-page yellow highlights: \(highlightCount)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        content.append(NSAttributedString(
            string: "Candidate passages: \(passages.count)\nLog file: \(MathPilotLogger.path)\n\n\(note)\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))

        if passages.isEmpty {
            content.append(NSAttributedString(
                string: "No candidates detected yet.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
        }

        for (index, passage) in passages.enumerated() {
            content.append(NSAttributedString(
                string: "\(index + 1). Page \(passage.pageIndex + 1) - \(passage.kind) - score \(passage.score)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
            content.append(NSAttributedString(
                string: passage.sentence + "\n",
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
            content.append(NSAttributedString(
                string: passage.explanation + "\n\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
        }

        sidebarView.textStorage?.setAttributedString(content)
    }

    private func makeToolbar() -> NSView {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let openButton = NSButton(title: "Open PDF", target: self, action: #selector(openPDFAction))
        openButton.bezelStyle = .rounded
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let rerunButton = NSButton(title: "Re-run Emphasis", target: self, action: #selector(rerunAction))
        rerunButton.bezelStyle = .rounded
        rerunButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingMiddle

        toolbar.addSubview(openButton)
        toolbar.addSubview(rerunButton)
        toolbar.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            openButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            openButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            rerunButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 8),
            rerunButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: rerunButton.trailingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        return toolbar
    }

    @objc private func openPDFAction() {
        openPDF()
    }

    @objc private func rerunAction() {
        emphasizeImportantText()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let readerViewController = ReaderViewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit EducationOSPDFReader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Open PDF...", action: #selector(openPDFFromMenu), keyEquivalent: "o"))
        fileMenuItem.submenu = fileMenu
        NSApplication.shared.mainMenu = mainMenu

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "EducationOS PDF Reader"
        window.center()
        window.contentViewController = readerViewController
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func openPDFFromMenu() {
        readerViewController.openPDF()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
enum EducationOSPDFReaderApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

EducationOSPDFReaderApp.main()

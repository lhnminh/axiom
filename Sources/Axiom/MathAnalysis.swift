import Foundation

enum MathAnalysisPrompt {
    static let maximumHighlightsPerPage = 5
    private static let maximumKeywordWords = 5

    static let instructions = """
    You are Axiom, an AI reading assistant for mathematics textbooks.
    Select at most 5 spans that a student must remember to understand this page. First identify the page's single primary learning objective, then select the central formula or named statement that expresses it. Add supporting spans only when they are necessary to interpret that primary item.
    If PAGE_TEXT contains a mathematical equality (`=`), you MUST return the most central complete equation as kind `equation` with importance 10 before returning any prose keywords.
    Rank importance strictly: 10 = the page's main theorem, definition, or complete displayed equation; 8-9 = an indispensable assumption or interpretation; 6-7 = essential notation; 1-5 = do not return it. Prefer one complete equation over its pieces and one complete statement over a surrounding paragraph.
    For prose, exact_text MUST be a compact keyword or noun phrase of 1 to 5 words, such as "prediction setting", "inference paradigm", or "irreducible error". Never return a full sentence, a clause beginning with "This" or "In this", or an explanatory sentence. Complete displayed equations are the only exception and may be returned in full.
    For every equation, also return display_formula: a clean, self-contained, human-readable Unicode display of that exact formula. Restore its visual reading order, line breaks, superscripts, subscripts, fractions, Greek letters, and aligned equals signs. Do not include prose labels such as "Reducible". This field is for display only, so it may correct PDF extraction order; exact_text must still be copied exactly from PAGE_TEXT. For non-equations, return an empty display_formula.
    Do not highlight routine prose, examples, figure captions, transitions, repeated terminology, or every related concept. Never return both a formula and one of its subexpressions, or overlapping parts of the same statement.
    exact_text is used to locate text in the PDF. It MUST be copied character-for-character from PAGE_TEXT, including mathematical symbols, punctuation, and spacing. Never rewrite a formula as LaTeX, prose, or an equivalent expression. For a formula, return the shortest distinctive exact fragment available in PAGE_TEXT; include a nearby label or sentence only when the formula alone is not distinctive.
    Keep each span focused and non-overlapping. Prefer a complete equation or a complete named statement over a vague surrounding paragraph.
    Before responding, rank all candidate spans internally and return only the highest-ranked non-overlapping ones. concepts should contain concise canonical names for concepts discussed by the highlighted span.
    Do not solve exercises. Do not include generic prose.
    """

    static func input(pageIndex: Int, text: String) -> String {
        "PAGE_INDEX: \(pageIndex)\nTEXT:\n\(text)"
    }

    static func mapHighlights(_ highlights: [MathHighlightCandidate], onto page: PageText) -> [ImportantPassage] {
        var seenText: Set<String> = []
        let mapped = highlights.compactMap { highlight -> ImportantPassage? in
            guard highlight.kind != "equation" || isUsableEquationSpan(highlight.exact_text) else {
                AxiomLogger.error("Discarded malformed equation span. page=\(page.pageIndex + 1), text=\(AxiomLogger.snippet(highlight.exact_text, limit: 180))")
                return nil
            }
            guard highlight.page_index == page.pageIndex,
                  let range = rangeForHighlight(highlight.exact_text, in: page.text) else {
                AxiomLogger.error(
                    "Could not map highlight to page. page=\(page.pageIndex + 1), kind=\(highlight.kind), text=\(AxiomLogger.snippet(highlight.exact_text, limit: 180))"
                )
                return nil
            }
            let normalizedText = TextFingerprint.normalized(highlight.exact_text).lowercased()
            guard !normalizedText.isEmpty,
                  isConciseHighlight(highlight.exact_text, kind: highlight.kind),
                  seenText.insert(normalizedText).inserted else { return nil }
            return ImportantPassage(
                pageIndex: page.pageIndex,
                sentence: highlight.exact_text,
                range: range,
                kind: highlight.kind,
                explanation: highlight.explanation,
                score: min(max(highlight.importance, 1), 10),
                concepts: highlight.concepts ?? [],
                formulaDisplay: cleanFormulaDisplay(highlight.display_formula, kind: highlight.kind)
            )
        }
        let hasEquation = mapped.contains { $0.kind == "equation" }
        let fallbackEquations = hasEquation ? [] : EquationFallback.passages(on: page)
        return selectHighlights(mapped + fallbackEquations)
    }

    private static func selectHighlights(_ passages: [ImportantPassage]) -> [ImportantPassage] {
        let ranked = passages.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsPriority = kindPriority(lhs.kind)
            let rhsPriority = kindPriority(rhs.kind)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
            return lhs.range.location < rhs.range.location
        }
        var selected: [ImportantPassage] = []
        for passage in ranked where selected.count < maximumHighlightsPerPage {
            guard !selected.contains(where: { rangesOverlap($0.range, passage.range) }) else { continue }
            selected.append(passage)
        }
        return selected.sorted { $0.range.location < $1.range.location }
    }

    private static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    private static func kindPriority(_ kind: String) -> Int {
        switch kind {
        case "theorem", "lemma", "corollary", "definition", "equation": 3
        case "notation": 2
        default: 1
        }
    }

    private static func isConciseHighlight(_ text: String, kind: String) -> Bool {
        if kind == "equation" { return true }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (1...maximumKeywordWords).contains(words.count) else { return false }
        let first = words.first?.lowercased() ?? ""
        return !["this", "that", "these", "those", "it", "we", "in"].contains(first)
    }

    private static func cleanFormulaDisplay(_ value: String?, kind: String) -> String? {
        guard kind == "equation",
              let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 1_200 else { return nil }
        return value
    }

    private static func isUsableEquationSpan(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("="),
              let first = trimmed.first,
              !["ˆ", "^", "=", "+", "−", "-"].contains(first) else { return false }
        return trimmed.count >= 8
    }

    private static func rangeForHighlight(_ highlightText: String, in pageText: String) -> NSRange? {
        let nsPageText = pageText as NSString
        let directRange = nsPageText.range(of: highlightText, options: [.caseInsensitive])
        if directRange.location != NSNotFound { return directRange }

        // PDFKit frequently changes a line break into a space (and vice versa), especially
        // inside displayed equations. Preserve every non-whitespace character and make only
        // whitespace flexible so equation punctuation and symbols remain precise.
        let parts = highlightText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return nil }
        let whitespaceFlexiblePattern = parts
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"\s+"#)
        if let regex = try? NSRegularExpression(pattern: whitespaceFlexiblePattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: pageText, range: NSRange(location: 0, length: nsPageText.length)) {
            return match.range
        }

        // Last resort for prose: tolerate PDF punctuation/line-break extraction differences,
        // but require enough words that a short formula cannot match an unrelated passage.
        let words = parts
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.rangeOfCharacter(from: .letters) != nil }
        guard words.count >= 4 else { return nil }
        let prosePattern = Array(words.prefix(14))
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"[\s\p{P}]*"#)
        guard let regex = try? NSRegularExpression(pattern: prosePattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(in: pageText, range: NSRange(location: 0, length: nsPageText.length))?.range
    }
}

private enum EquationFallback {
    static func passages(on page: PageText) -> [ImportantPassage] {
        let lines = page.text.components(separatedBy: .newlines)
        var candidates: [(text: String, start: Int)] = []

        for index in lines.indices where lines[index].contains("=") && isMathLine(lines[index]) {
            var start = index
            while start > 0, index - start < 4, isMathLine(lines[start - 1]) { start -= 1 }
            var end = index
            while end + 1 < lines.count, end - index < 8, isMathLine(lines[end + 1]) { end += 1 }
            var selectedLines = Array(lines[start...end])
            while let last = selectedLines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ["ˆ", "^", "′"].contains(last) {
                selectedLines.removeLast()
            }
            let text = selectedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 8 else { continue }
            candidates.append((text, start))
        }

        guard let candidate = candidates.max(by: { $0.text.count < $1.text.count }),
              let range = exactRange(candidate.text, in: page.text) else { return [] }
        return [
            ImportantPassage(
                pageIndex: page.pageIndex,
                sentence: candidate.text,
                range: range,
                kind: "equation",
                explanation: "Central displayed equation detected from the page text.",
                score: 10,
                concepts: [],
                formulaDisplay: nil
            )
        ]
    }

    private static func isMathLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        if ["Reducible", "Irreducible"].contains(trimmed) { return true }
        return trimmed.contains("=") || trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "ˆϵ−+[]()²")) != nil
    }

    private static func exactRange(_ text: String, in pageText: String) -> NSRange? {
        let range = (pageText as NSString).range(of: text)
        return range.location == NSNotFound ? nil : range
    }
}

enum PageChunker {
    static func chunks(text: String, maximumCharacters: Int = 18_000) -> [String] {
        guard text.count > maximumCharacters else { return [text] }
        var chunks: [String] = []
        var current = ""
        let paragraphs = text.components(separatedBy: "\n\n")

        for paragraph in paragraphs {
            if current.count + paragraph.count + 2 <= maximumCharacters {
                current += current.isEmpty ? paragraph : "\n\n\(paragraph)"
                continue
            }
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            var remainder = paragraph
            while remainder.count > maximumCharacters {
                let end = remainder.index(remainder.startIndex, offsetBy: maximumCharacters)
                chunks.append(String(remainder[..<end]))
                remainder = String(remainder[end...])
            }
            current = remainder
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

@MainActor
final class ConfiguredMathAnalyzer {
    private enum Provider { case gemini, openai }

    private let provider: Provider
    private let gemini: GeminiMathAnalyzer
    private let openAI: OpenAIMathAnalyzer
    private var requestInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var rateLimitUntil: Date?

    let providerName: String
    let modelName: String

    var identity: AnalysisIdentity {
        AnalysisIdentity(provider: providerName, model: modelName, promptVersion: AnalysisIdentity.promptVersion)
    }

    var isConfigured: Bool {
        switch provider {
        case .gemini: gemini.isConfigured
        case .openai: openAI.isConfigured
        }
    }

    var missingConfigurationMessage: String {
        "\(providerName) is selected, but its API key is missing from .env."
    }

    init(environment: [String: String] = Dotenv.mergedEnvironment()) {
        gemini = GeminiMathAnalyzer(environment: environment)
        openAI = OpenAIMathAnalyzer(environment: environment)
        let selected = environment["AI_PROVIDER"]?.lowercased()
        if selected == "openai" || (selected == nil && openAI.isConfigured && !gemini.isConfigured) {
            provider = .openai
            providerName = "OpenAI"
            modelName = openAI.model
        } else {
            provider = .gemini
            providerName = "Gemini"
            modelName = gemini.model
        }
        AxiomLogger.info(
            "Configured AI provider=\(providerName), model=\(modelName), configured=\(isConfigured), promptVersion=\(AnalysisIdentity.promptVersion)"
        )
    }

    func passages(page: PageText, limit: Int = MathAnalysisPrompt.maximumHighlightsPerPage) async throws -> [ImportantPassage] {
        if let rateLimitUntil {
            let remaining = rateLimitUntil.timeIntervalSinceNow
            guard remaining <= 0 else {
                throw RemoteAnalyzerError.rateLimited(retryAfterSeconds: max(1, Int(ceil(remaining))))
            }
            self.rateLimitUntil = nil
        }
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
        do {
            var candidates: [MathHighlightCandidate] = []
            for chunk in PageChunker.chunks(text: page.text) {
                let response: MathHighlightResponse
                switch provider {
                case .gemini:
                    response = try await gemini.analyze(pageIndex: page.pageIndex, text: chunk, limit: limit)
                case .openai:
                    response = try await openAI.analyze(pageIndex: page.pageIndex, text: chunk, limit: limit)
                }
                candidates.append(contentsOf: response.highlights)
            }
            return MathAnalysisPrompt.mapHighlights(candidates, onto: page)
        } catch let error as RemoteAnalyzerError {
            if let seconds = error.retryAfterSeconds {
                // Add a small buffer so a button click at the displayed boundary does not
                // immediately consume another limited request.
                rateLimitUntil = Date().addingTimeInterval(TimeInterval(seconds + 2))
            }
            throw error
        }
    }

    private func acquireRequestSlot() async {
        if !requestInFlight {
            requestInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if requestWaiters.isEmpty {
            requestInFlight = false
        } else {
            requestWaiters.removeFirst().resume()
        }
    }
}

@MainActor
final class GeminiMathAnalyzer {
    private let apiKey: String?
    let model: String
    var isConfigured: Bool { apiKey?.isEmpty == false }

    init(environment: [String: String]) {
        apiKey = environment["GEMINI_API_KEY"]
        model = environment["GEMINI_MODEL"] ?? "gemini-3.1-flash-lite"
    }

    func analyze(pageIndex: Int, text: String, limit: Int) async throws -> MathHighlightResponse {
        guard let apiKey, !apiKey.isEmpty else { throw RemoteAnalyzerError.missingAPIKey }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions") else {
            throw RemoteAnalyzerError.invalidURL
        }
        let schema = Self.schema(limit: limit)
        let input = """
        \(MathAnalysisPrompt.instructions)

        Return at most \(limit) highlights.

        \(MathAnalysisPrompt.input(pageIndex: pageIndex, text: text))
        """
        // Gemini 2.5 Flash-Lite accepts low/high, whereas Gemini 3.1 Flash-Lite
        // and Gemini 3.5 Flash accept minimal. Keep the setting compatible with either.
        let thinkingLevel = model.lowercased().contains("2.5") ? "low" : "minimal"
        let body: [String: Any] = [
            "model": model,
            "input": input,
            "generation_config": ["thinking_level": thinkingLevel],
            "response_format": ["type": "text", "mime_type": "application/json", "schema": schema],
            "store": false
        ]
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = ContinuousClock.now
        AxiomLogger.info(
            "Gemini page request starting. model=\(model), page=\(pageIndex + 1), inputCharacters=\(text.count), key=\(AxiomLogger.redact(apiKey))"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RemoteAnalyzerError.invalidResponse(statusCode: status, body: AxiomLogger.snippet(data))
        }
        AxiomLogger.info(
            "Gemini page request succeeded. page=\(pageIndex + 1), durationMs=\(AxiomLogger.durationMilliseconds(since: started)), responseBytes=\(data.count)"
        )
        AxiomLogger.writeDebugFile(name: "axiom-last-gemini-response.json", data: data)
        let output = try Self.extractOutputText(data)
        do {
            return try JSONDecoder().decode(MathHighlightResponse.self, from: Data(output.utf8))
        } catch {
            throw RemoteAnalyzerError.outputDecodeFailed(String(describing: error))
        }
    }

    private static func extractOutputText(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw RemoteAnalyzerError.missingOutputText(body: AxiomLogger.snippet(data))
        }
        if let output = dictionary["output_text"] as? String { return clean(output) }
        if let found = findHighlightJSON(object) { return clean(found) }
        throw RemoteAnalyzerError.missingOutputText(body: AxiomLogger.snippet(data))
    }

    private static func findHighlightJSON(_ value: Any) -> String? {
        if let string = value as? String, string.contains("highlights") { return string }
        if let array = value as? [Any] {
            for item in array { if let found = findHighlightJSON(item) { return found } }
        }
        if let dictionary = value as? [String: Any] {
            for item in dictionary.values { if let found = findHighlightJSON(item) { return found } }
        }
        return nil
    }

    private static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        if let start = result.firstIndex(of: "{"), let end = result.lastIndex(of: "}") {
            result = String(result[start...end])
        }
        return result
    }

    fileprivate static func schema(limit: Int) -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "highlights": [
                    "type": "array",
                    "maxItems": limit,
                    "items": [
                        "type": "object",
                        "properties": [
                            "page_index": ["type": "integer"],
                            "exact_text": ["type": "string"],
                            "kind": ["type": "string", "enum": ["definition", "theorem", "lemma", "corollary", "equation", "notation", "concept"]],
                            "explanation": ["type": "string"],
                            "importance": ["type": "integer"],
                            "concepts": ["type": "array", "items": ["type": "string"]],
                            "display_formula": ["type": "string"]
                        ],
                        "required": ["page_index", "exact_text", "kind", "explanation", "importance", "concepts", "display_formula"]
                    ]
                ]
            ],
            "required": ["highlights"]
        ]
    }
}

@MainActor
final class OpenAIMathAnalyzer {
    private let apiKey: String?
    let model: String
    var isConfigured: Bool { apiKey?.isEmpty == false }

    init(environment: [String: String]) {
        apiKey = environment["OPENAI_API_KEY"]
        model = environment["OPENAI_MODEL"] ?? "gpt-5.2"
    }

    func analyze(pageIndex: Int, text: String, limit: Int) async throws -> MathHighlightResponse {
        guard let apiKey, !apiKey.isEmpty else { throw RemoteAnalyzerError.missingAPIKey }
        guard let url = URL(string: "https://api.openai.com/v1/responses") else {
            throw RemoteAnalyzerError.invalidURL
        }
        let body: [String: Any] = [
            "model": model,
            "instructions": MathAnalysisPrompt.instructions,
            "input": MathAnalysisPrompt.input(pageIndex: pageIndex, text: text),
            "text": ["format": [
                "type": "json_schema",
                "name": "axiom_page_highlights",
                "schema": GeminiMathAnalyzer.schema(limit: limit),
                "strict": true
            ]]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let started = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw RemoteAnalyzerError.invalidResponse(statusCode: status, body: AxiomLogger.snippet(data))
        }
        AxiomLogger.info(
            "OpenAI page request succeeded. page=\(pageIndex + 1), durationMs=\(AxiomLogger.durationMilliseconds(since: started)), responseBytes=\(data.count)"
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], let output = dictionary["output"] as? [[String: Any]] else {
            throw RemoteAnalyzerError.missingOutputText(body: AxiomLogger.snippet(data))
        }
        for item in output {
            if let content = item["content"] as? [[String: Any]] {
                for part in content {
                    if let text = part["text"] as? String {
                        return try JSONDecoder().decode(MathHighlightResponse.self, from: Data(text.utf8))
                    }
                }
            }
        }
        throw RemoteAnalyzerError.missingOutputText(body: AxiomLogger.snippet(data))
    }
}

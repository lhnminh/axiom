import Foundation

enum MathAnalysisPrompt {
    static let instructions = """
    You are Axiom, an AI reading assistant for mathematics textbooks.
    Identify only text spans that should be visually highlighted on the supplied page.
    Prefer definitions, theorems, lemmas, corollaries, equations, notation, and central concepts.
    exact_text must be copied exactly from the page text and should be short enough to highlight directly.
    concepts should contain concise canonical names for concepts discussed by the highlighted span.
    Do not solve exercises. Do not include generic prose.
    """

    static func input(pageIndex: Int, text: String) -> String {
        "PAGE_INDEX: \(pageIndex)\nTEXT:\n\(text)"
    }

    static func mapHighlights(_ highlights: [MathHighlightCandidate], onto page: PageText) -> [ImportantPassage] {
        var seen: Set<String> = []
        return highlights.compactMap { highlight in
            guard highlight.page_index == page.pageIndex,
                  let range = rangeForHighlight(highlight.exact_text, in: page.text) else {
                AxiomLogger.error(
                    "Could not map highlight to page. page=\(page.pageIndex + 1), kind=\(highlight.kind), text=\(AxiomLogger.snippet(highlight.exact_text, limit: 180))"
                )
                return nil
            }
            let key = "\(range.location):\(range.length):\(highlight.kind)"
            guard seen.insert(key).inserted else { return nil }
            return ImportantPassage(
                pageIndex: page.pageIndex,
                sentence: highlight.exact_text,
                range: range,
                kind: highlight.kind,
                explanation: highlight.explanation,
                score: min(max(highlight.importance, 1), 10),
                concepts: highlight.concepts ?? []
            )
        }
    }

    private static func rangeForHighlight(_ highlightText: String, in pageText: String) -> NSRange? {
        let nsPageText = pageText as NSString
        let directRange = nsPageText.range(of: highlightText, options: [.caseInsensitive])
        if directRange.location != NSNotFound { return directRange }

        let words = highlightText
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 4 else { return nil }
        let pattern = Array(words.prefix(14))
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"[\s\p{P}]*"#)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regex.firstMatch(
            in: pageText,
            range: NSRange(location: 0, length: nsPageText.length)
        )?.range
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

    func passages(page: PageText, limit: Int = 16) async throws -> [ImportantPassage] {
        await acquireRequestSlot()
        defer { releaseRequestSlot() }
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
        model = environment["GEMINI_MODEL"] ?? "gemini-3.5-flash"
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
        let body: [String: Any] = [
            "model": model,
            "input": input,
            "generation_config": ["thinking_level": "minimal"],
            "response_format": ["type": "text", "mime_type": "application/json", "schema": schema],
            "store": false
        ]
        var request = URLRequest(url: url)
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
                            "concepts": ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": ["page_index", "exact_text", "kind", "explanation", "importance", "concepts"]
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

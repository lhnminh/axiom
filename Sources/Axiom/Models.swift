import CryptoKit
import Foundation

struct ImportantPassage: Sendable {
    let pageIndex: Int
    let sentence: String
    let range: NSRange
    let kind: String
    let explanation: String
    let score: Int
    let concepts: [String]
}

struct PageText: Sendable {
    let pageIndex: Int
    let text: String
}

struct MathHighlightCandidate: Codable, Sendable {
    let page_index: Int
    let exact_text: String
    let kind: String
    let explanation: String
    let importance: Int
    let concepts: [String]?
}

struct MathHighlightResponse: Codable, Sendable {
    let highlights: [MathHighlightCandidate]
}

struct TextbookSummary: Identifiable, Sendable {
    let id: Int64
    let path: String
    let displayName: String
    let bookmark: Data?
    let fileFingerprint: String
    let pageCount: Int
    let extractedPages: Int
    let extractionStatus: String
    let error: String?
}

struct StoredPage: Sendable {
    let textbookID: Int64
    let pageIndex: Int
    let text: String
    let fingerprint: String
    let extractionStatus: String
    let analysisStatus: String
    let analysisError: String?
}

struct StoredHighlight: Sendable {
    let pageIndex: Int
    let exactText: String
    let location: Int
    let length: Int
    let kind: String
    let explanation: String
    let importance: Int
    let concepts: [String]

    var passage: ImportantPassage {
        ImportantPassage(
            pageIndex: pageIndex,
            sentence: exactText,
            range: NSRange(location: location, length: length),
            kind: kind,
            explanation: explanation,
            score: importance,
            concepts: concepts
        )
    }
}

struct AnalysisIdentity: Sendable {
    static let promptVersion = "page-highlights-v2"

    let provider: String
    let model: String
    let promptVersion: String
}

enum CachedPageAnalysis: Sendable {
    case missing
    case analyzing
    case ready([StoredHighlight])
    case failed(String)
}

enum TextFingerprint {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func make(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(normalized(text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum RemoteAnalyzerError: Error {
    case missingAPIKey
    case invalidURL
    case rateLimited(retryAfterSeconds: Int)
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
        case let .rateLimited(retryAfterSeconds):
            "Gemini is rate limited. Wait about \(retryAfterSeconds) seconds before retrying this page."
        case let .invalidResponse(statusCode, body):
            "HTTP \(statusCode): \(body)"
        case let .missingOutputText(body):
            "Could not find output text in response: \(body)"
        case let .outputDecodeFailed(message):
            "Could not decode model JSON: \(message)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case let .invalidResponse(statusCode, _):
            // Retrying a quota response immediately consumes more requests and makes the
            // user wait longer. The UI exposes Retry Page for a deliberate later attempt.
            return (500...599).contains(statusCode)
        default:
            return false
        }
    }

    var retryAfterSeconds: Int? {
        guard case let .invalidResponse(statusCode, body) = self, statusCode == 429 else { return nil }
        let pattern = #"Please retry in ([0-9.]+)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body),
              let value = Double(body[range]) else {
            return 60
        }
        return max(1, Int(ceil(value)))
    }

    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return retryAfterSeconds != nil
    }
}

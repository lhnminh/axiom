import Foundation

enum AxiomLogger {
    private static let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("axiom.log")

    static var path: String { logURL.path }

    static func info(_ message: String) { write(level: "INFO", message) }
    static func error(_ message: String) { write(level: "ERROR", message) }

    static func redact(_ value: String) -> String {
        guard value.count > 8 else { return "<redacted>" }
        return "\(value.prefix(4))...\(value.suffix(4))"
    }

    static func snippet(_ data: Data, limit: Int = 2_000) -> String {
        snippet(String(data: data, encoding: .utf8) ?? "<non-utf8 response>", limit: limit)
    }

    static func snippet(_ text: String, limit: Int = 2_000) -> String {
        String(text.prefix(limit))
    }

    static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000)
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    static func writeDebugFile(name: String, data: Data) {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name)
        do {
            try data.write(to: url)
            info("Wrote debug response file: \(url.path)")
        } catch {
            self.error("Failed to write debug response file \(url.path): \(error)")
        }
    }

    private static func write(level: String, _ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] [\(level)] \(message)\n"
        print(line, terminator: "")
        guard let data = line.data(using: .utf8) else { return }

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
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}

enum PDFDiscovery {
    static func pdfURLs(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "pdf",
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                continue
            }
            results.append(url)
        }
        return results.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

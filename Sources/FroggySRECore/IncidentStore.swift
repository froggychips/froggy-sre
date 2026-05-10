import Foundation

public struct StoredIncident: Codable, Sendable {
    public let timestamp: Date
    public let report: IncidentReport
}

/// Persists incident reports as JSON files under ~/.froggy-sre/incidents/.
public actor IncidentStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        directory = home.appendingPathComponent(".froggy-sre/incidents", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ report: IncidentReport) throws {
        let stored = StoredIncident(timestamp: Date(), report: report)
        let data = try encoder.encode(stored)
        let name = filename(timestamp: stored.timestamp, labels: report.incident.labels)
        try data.write(to: directory.appendingPathComponent(name))
    }

    public func load(limit: Int = 10) throws -> [StoredIncident] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // ISO8601 lexsort = chrono
            .prefix(limit)
            .compactMap { try? decoder.decode(StoredIncident.self, from: Data(contentsOf: $0)) }
    }

    private func filename(timestamp: Date, labels: [String: String]) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let ts = fmt.string(from: timestamp).replacingOccurrences(of: ":", with: "-")
        let alert = (labels["alertname"] ?? "unknown")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "\(ts)-\(alert).json"
    }
}

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
        let env  = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = env["FROGGY_SRE_INCIDENTS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".froggy-sre/incidents", isDirectory: true)
        self.init(directory: dir)
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ report: IncidentReport) throws {
        let stored = StoredIncident(timestamp: Date(), report: report)
        let data   = try encoder.encode(stored)
        let name   = filename(timestamp: stored.timestamp, labels: report.incident.labels)
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
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // ISO8601 lexsort = chrono desc
            .prefix(limit)
            .compactMap { try? decoder.decode(StoredIncident.self, from: Data(contentsOf: $0)) }
    }

    /// Returns the N most recent stored incidents with the same alertname.
    public func findSimilar(to incident: Incident, limit: Int = 3) throws -> [StoredIncident] {
        let alertname = incident.labels["alertname"] ?? ""
        return Array(
            try load(limit: 50)
                .filter { $0.report.incident.labels["alertname"] == alertname }
                .prefix(limit)
        )
    }

    private func filename(timestamp: Date, labels: [String: String]) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let ts    = fmt.string(from: timestamp).replacingOccurrences(of: ":", with: "-")
        let alert = (labels["alertname"] ?? "unknown")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "\(ts)-\(alert).json"
    }
}

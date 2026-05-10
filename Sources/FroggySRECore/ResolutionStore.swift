import Foundation

/// Persists resolved incidents to ~/.froggy-sre/resolved/ (local only, never in git).
/// No pruning — resolved cases are kept indefinitely as the eval dataset.
public actor ResolutionStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let env  = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = env["FROGGY_SRE_RESOLVED_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".froggy-sre/resolved", isDirectory: true)
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting     = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ resolved: ResolvedIncident) throws {
        let data = try encoder.encode(resolved)
        let fmt  = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts    = fmt.string(from: resolved.stored.timestamp).replacingOccurrences(of: ":", with: "-")
        let alert = (resolved.stored.report.incident.labels["alertname"] ?? "unknown")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        try data.write(to: directory.appendingPathComponent("\(ts)-\(alert).json"))
    }

    public func load(limit: Int = 20) throws -> [ResolvedIncident] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .compactMap { try? decoder.decode(ResolvedIncident.self, from: Data(contentsOf: $0)) }
    }
}

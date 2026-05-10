import Foundation

public struct Resolution: Codable, Sendable {
    public let actualFix: String
    public let commitUrl: String?
    public let resolvedAt: Date
}

public struct ResolutionScore: Codable, Sendable {
    /// 0–1: how closely the hypothesis matched the real root cause. -1 = scoring failed.
    public let rootCauseScore: Double
    /// 0–1: how closely the proposed fix matched the actual fix. -1 = scoring failed.
    public let fixScore: Double
    public let rationale: String
}

public struct ResolvedIncident: Codable, Sendable {
    public let stored: StoredIncident
    public let resolution: Resolution
    public let score: ResolutionScore
}

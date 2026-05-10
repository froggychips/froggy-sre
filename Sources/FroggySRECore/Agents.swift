// Stub agents — each will become a full actor with prompt + LLM call.

public struct Incident: Sendable {
    public let labels: [String: String]
    public let annotations: [String: String]
    public let startsAt: String

    public init(labels: [String: String], annotations: [String: String], startsAt: String) {
        self.labels = labels
        self.annotations = annotations
        self.startsAt = startsAt
    }
}

public struct IncidentReport: Sendable {
    public let incident: Incident
    public let risk: RiskResult
}

public struct Analysis: Sendable   { public let summary: String }
public struct Hypothesis: Sendable { public let rootCause: String }
public struct Critique: Sendable   { public let validated: Bool; public let notes: String }
public struct Fix: Sendable        { public let action: String }
public struct RiskResult: Sendable { public let score: Double; public let rationale: String }

public actor Analyzer        { public init() {}; public func run(_ i: Incident)   async throws -> Analysis   { Analysis(summary: "") } }
public actor HypothesisAgent { public init() {}; public func run(_ a: Analysis)  async throws -> Hypothesis { Hypothesis(rootCause: "") } }
public actor CriticAgent     { public init() {}; public func run(_ h: Hypothesis) async throws -> Critique   { Critique(validated: false, notes: "") } }
public actor FixAgent        { public init() {}; public func run(_ c: Critique)   async throws -> Fix        { Fix(action: "") } }
public actor RiskAgent       { public init() {}; public func run(_ f: Fix)        async throws -> RiskResult { RiskResult(score: 0, rationale: "") } }

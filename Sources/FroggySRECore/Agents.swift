import Foundation

// MARK: - Domain types

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
    public let analysis: Analysis
    public let hypothesis: Hypothesis
    public let fix: Fix
    public let risk: RiskResult
}

public struct Analysis: Sendable   { public let summary: String }
public struct Hypothesis: Sendable { public let rootCause: String }
public struct Critique: Sendable   { public let validated: Bool; public let notes: String }
public struct Fix: Sendable        { public let action: String }
public struct RiskResult: Sendable { public let score: Double; public let rationale: String }

// MARK: - Analyzer (real LLM call)

public actor Analyzer {
    private let llm = AnthropicClient()

    public init() {}

    public func run(_ incident: Incident) async throws -> Analysis {
        let labels = incident.labels
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let annotations = incident.annotations
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n")

        let text = try await llm.complete(
            system: "You are a senior SRE analyzing a Kubernetes alert. Be concise and technical. 2-3 sentences.",
            user: """
            Alert: \(labels)
            \(annotations.isEmpty ? "" : "Details:\n\(annotations)")
            Started: \(incident.startsAt)

            What is happening and what is the immediate impact?
            """
        )
        return Analysis(summary: text)
    }
}

// MARK: - Hypothesis, Critic, Fix, Risk (stubs — follow-up PRs)

public actor HypothesisAgent {
    public init() {}
    public func run(_ a: Analysis) async throws -> Hypothesis {
        Hypothesis(rootCause: "[stub] \(a.summary)")
    }
}

public actor CriticAgent {
    public init() {}
    public func run(_ h: Hypothesis) async throws -> Critique {
        Critique(validated: true, notes: h.rootCause)
    }
}

public actor FixAgent {
    public init() {}
    public func run(_ c: Critique) async throws -> Fix {
        Fix(action: "[stub] Remediation analysis pending implementation.")
    }
}

public actor RiskAgent {
    public init() {}
    public func run(_ f: Fix) async throws -> RiskResult {
        RiskResult(score: 0.5, rationale: "[stub] Risk scoring pending implementation.")
    }
}

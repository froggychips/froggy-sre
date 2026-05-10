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

    var labelString: String {
        labels.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
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

// MARK: - Analyzer

public actor Analyzer {
    private let llm = AnthropicClient()
    public init() {}

    public func run(_ incident: Incident) async throws -> Analysis {
        let annotations = incident.annotations
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let text = try await llm.complete(
            system: "You are a senior SRE analyzing a Kubernetes alert. Be concise and technical. 2-3 sentences.",
            user: """
            Alert: \(incident.labelString)
            \(annotations.isEmpty ? "" : "Details:\n\(annotations)")
            Started: \(incident.startsAt)

            What is happening and what is the immediate impact?
            """
        )
        return Analysis(summary: text)
    }
}

// MARK: - HypothesisAgent

public actor HypothesisAgent {
    private let llm = AnthropicClient()
    public init() {}

    public func run(_ incident: Incident, _ analysis: Analysis) async throws -> Hypothesis {
        let text = try await llm.complete(
            system: "You are an SRE investigating a Kubernetes incident. Generate a specific root cause hypothesis. Technical, 2-3 sentences.",
            user: """
            Incident: \(incident.labelString)
            Analysis: \(analysis.summary)

            What is the most likely root cause?
            """
        )
        return Hypothesis(rootCause: text)
    }
}

// MARK: - CriticAgent

public actor CriticAgent {
    private let llm = AnthropicClient()
    public init() {}

    public func run(_ incident: Incident, _ hypothesis: Hypothesis) async throws -> Critique {
        let text = try await llm.complete(
            system: "You are a skeptical SRE reviewer. Critically evaluate this root cause hypothesis. Identify weaknesses or missing context. 2-3 sentences.",
            user: """
            Incident: \(incident.labelString)
            Hypothesis: \(hypothesis.rootCause)

            Is this plausible? What might be wrong or missing?
            """
        )
        return Critique(validated: true, notes: text)
    }
}

// MARK: - FixAgent

public actor FixAgent {
    private let llm = AnthropicClient()
    public init() {}

    public func run(_ incident: Incident, _ critique: Critique) async throws -> Fix {
        let text = try await llm.complete(
            system: "You are an SRE proposing a remediation. Suggest a concrete, safe fix. Include specific kubectl commands or config changes where applicable. 2-3 sentences.",
            user: """
            Incident: \(incident.labelString)
            Root cause analysis: \(critique.notes)

            What is the safest, most effective fix?
            """
        )
        return Fix(action: text)
    }
}

// MARK: - RiskAgent

public actor RiskAgent {
    private let llm = AnthropicClient()
    public init() {}

    public func run(_ incident: Incident, _ fix: Fix) async throws -> RiskResult {
        let text = try await llm.complete(
            system: """
            You are an SRE risk assessor. Evaluate the risk of applying a proposed fix.
            Respond in this exact format:
            SCORE: <0.0 to 1.0>
            RATIONALE: <one sentence>
            """,
            user: """
            Incident: \(incident.labelString)
            Proposed fix: \(fix.action)

            What is the risk score?
            """
        )
        return parseRisk(text)
    }

    private func parseRisk(_ text: String) -> RiskResult {
        var score = 0.5
        var rationale = text
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("SCORE:") {
                let s = line.dropFirst("SCORE:".count).trimmingCharacters(in: .whitespaces)
                score = min(max(Double(s) ?? 0.5, 0.0), 1.0)
            } else if line.hasPrefix("RATIONALE:") {
                rationale = String(line.dropFirst("RATIONALE:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return RiskResult(score: score, rationale: rationale)
    }
}

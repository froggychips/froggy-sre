import Foundation

// MARK: - Domain types

public struct Incident: Sendable, Codable {
    public let labels: [String: String]
    public let annotations: [String: String]
    public let startsAt: String
    public let k8sContext: K8sContext?

    public init(
        labels: [String: String],
        annotations: [String: String],
        startsAt: String,
        k8sContext: K8sContext? = nil
    ) {
        self.labels     = labels
        self.annotations = annotations
        self.startsAt   = startsAt
        self.k8sContext = k8sContext
    }

    var labelString: String {
        labels.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

public struct IncidentReport: Sendable, Codable {
    public let incident: Incident
    public let analysis: Analysis
    public let hypothesis: Hypothesis
    public let fix: Fix
    public let risk: RiskResult
}

public struct Analysis: Sendable, Codable   { public let summary: String }
public struct Hypothesis: Sendable, Codable { public let rootCause: String }
public struct Critique: Sendable, Codable   { public let validated: Bool; public let notes: String }
public struct Fix: Sendable, Codable        { public let action: String }
public struct RiskResult: Sendable, Codable { public let score: Double; public let rationale: String }

// MARK: - Analyzer

public actor Analyzer {
    private let llm = LLMRouter()
    public init() {}

    public func run(_ incident: Incident) async throws -> Analysis {
        let annotations = incident.annotations.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        var ctx = ""
        if let k = incident.k8sContext {
            if let logs = k.podLogs   { ctx += "\nPod logs (tail):\n```\n\(logs)\n```" }
            if let evts = k.recentEvents { ctx += "\nRecent k8s warning events:\n```\n\(evts)\n```" }
        }
        let text = try await llm.complete(
            system: "You are a senior SRE analyzing a Kubernetes alert. Be concise and technical. 2-3 sentences.",
            user: """
            Alert: \(incident.labelString)
            \(annotations.isEmpty ? "" : "Annotations:\n\(annotations)")
            \(ctx)
            Started: \(incident.startsAt)

            What is happening and what is the immediate impact?
            """
        )
        return Analysis(summary: text)
    }
}

// MARK: - HypothesisAgent

public actor HypothesisAgent {
    private let llm = LLMRouter()
    public init() {}

    public func run(_ incident: Incident, _ analysis: Analysis) async throws -> Hypothesis {
        var ctx = ""
        if let desc = incident.k8sContext?.podDescription {
            ctx = "\nPod description:\n```\n\(desc)\n```"
        }
        let text = try await llm.complete(
            system: "You are an SRE investigating a Kubernetes incident. Generate a specific root cause hypothesis. Technical, 2-3 sentences.",
            user: """
            Incident: \(incident.labelString)
            Analysis: \(analysis.summary)
            \(ctx)

            What is the most likely root cause?
            """
        )
        return Hypothesis(rootCause: text)
    }
}

// MARK: - CriticAgent

public actor CriticAgent {
    private let llm = LLMRouter()
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
    private let llm = LLMRouter()
    public init() {}

    public func run(_ incident: Incident, _ critique: Critique) async throws -> Fix {
        var ctx = ""
        if let evts = incident.k8sContext?.recentEvents {
            ctx = "\nRecent k8s events:\n```\n\(evts)\n```"
        }
        let text = try await llm.complete(
            system: "You are an SRE proposing a remediation. Suggest a concrete, safe fix. Include specific kubectl commands or config changes where applicable. 2-3 sentences.",
            user: """
            Incident: \(incident.labelString)
            Root cause analysis: \(critique.notes)
            \(ctx)

            What is the safest, most effective fix?
            """
        )
        return Fix(action: text)
    }
}

// MARK: - RiskAgent

public actor RiskAgent {
    private let llm = LLMRouter()
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

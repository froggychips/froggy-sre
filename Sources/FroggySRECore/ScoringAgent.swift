import Foundation

/// Compares the pipeline's predicted hypothesis + fix against the actual resolution
/// and produces a 0–1 score for each dimension.
public actor ScoringAgent {
    private let llm: any LLMCompleting
    public init(llm: any LLMCompleting = LLMRouter()) { self.llm = llm }

    public func score(report: IncidentReport, resolution: Resolution) async throws -> ResolutionScore {
        let commitLine = resolution.commitUrl.map { "Commit: \($0)" } ?? ""
        let text = try await llm.complete(
            system: """
            You are an SRE evaluator comparing a predicted diagnosis with the actual resolution.
            Respond in exactly this format (nothing else):
            ROOT_CAUSE_SCORE: <0.0 to 1.0>
            FIX_SCORE: <0.0 to 1.0>
            RATIONALE: <one sentence explaining both scores>
            """,
            user: """
            Incident: \(report.incident.labelString)

            PREDICTED root cause: \(report.hypothesis.rootCause)
            PREDICTED fix: \(report.fix.action)

            ACTUAL fix applied: \(resolution.actualFix)
            \(commitLine)

            ROOT_CAUSE_SCORE: 1.0 means the hypothesis identified the exact root cause.
            FIX_SCORE: 1.0 means the proposed fix matches exactly what was done.
            Score 0.5 for same general area but wrong specifics. Score 0.0 for completely wrong.
            """
        )
        return parse(text)
    }

    private func parse(_ text: String) -> ResolutionScore {
        var rcScore  = -1.0
        var fixScore = -1.0
        var rationale = text
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("ROOT_CAUSE_SCORE:") {
                rcScore = clamp(Double(trimmed.dropFirst("ROOT_CAUSE_SCORE:".count).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("FIX_SCORE:") {
                fixScore = clamp(Double(trimmed.dropFirst("FIX_SCORE:".count).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("RATIONALE:") {
                rationale = String(trimmed.dropFirst("RATIONALE:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ResolutionScore(rootCauseScore: rcScore, fixScore: fixScore, rationale: rationale)
    }

    private func clamp(_ v: Double?) -> Double {
        guard let v else { return -1 }
        return v < 0 ? -1 : min(max(v, 0), 1)
    }
}

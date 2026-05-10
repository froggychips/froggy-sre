/// Five-stage incident analysis pipeline.
/// Mirrors sre-ai-copilot chain: Analyzer → Hypothesis → Critic → Fix → Risk.
/// LLM calls go to Anthropic API (v0.1); local Froggy inference planned for v0.2.
public actor AgentPipeline {
    public init() {}

    public func process(_ incident: Incident) async throws -> IncidentReport {
        let analysis   = try await Analyzer().run(incident)
        let hypothesis = try await HypothesisAgent().run(analysis)
        let critique   = try await CriticAgent().run(hypothesis)
        let fix        = try await FixAgent().run(critique)
        let risk       = try await RiskAgent().run(fix)
        return IncidentReport(
            incident: incident,
            analysis: analysis,
            hypothesis: hypothesis,
            fix: fix,
            risk: risk
        )
    }
}

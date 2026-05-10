/// Five-stage incident analysis pipeline.
/// Mirrors sre-ai-copilot chain: Analyzer → Hypothesis → Critic → Fix → Risk.
/// LLM calls go to Froggy local inference or Anthropic API as fallback.
public actor AgentPipeline {
    public init() {}

    public func process(_ incident: Incident) async throws -> IncidentReport {
        let analysis   = try await Analyzer().run(incident)
        let hypothesis = try await HypothesisAgent().run(analysis)
        let critique   = try await CriticAgent().run(hypothesis)
        let fix        = try await FixAgent().run(critique)
        let risk       = try await RiskAgent().run(fix)
        return IncidentReport(incident: incident, risk: risk)
    }
}

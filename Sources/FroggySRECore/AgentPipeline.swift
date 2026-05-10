/// Five-stage incident analysis pipeline.
/// Each agent receives the original Incident for context + the previous stage's output.
public actor AgentPipeline {
    public init() {}

    public func process(_ incident: Incident) async throws -> IncidentReport {
        let analysis   = try await Analyzer().run(incident)
        let hypothesis = try await HypothesisAgent().run(incident, analysis)
        let critique   = try await CriticAgent().run(incident, hypothesis)
        let fix        = try await FixAgent().run(incident, critique)
        let risk       = try await RiskAgent().run(incident, fix)
        return IncidentReport(
            incident:   incident,
            analysis:   analysis,
            hypothesis: hypothesis,
            fix:        fix,
            risk:       risk
        )
    }
}

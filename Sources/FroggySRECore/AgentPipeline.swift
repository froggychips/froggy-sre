/// Five-stage incident analysis pipeline.
/// Enriches the incident with live k8s context before the first agent runs.
public actor AgentPipeline {
    public init() {}

    public func process(_ incident: Incident) async throws -> IncidentReport {
        let ctx      = await K8sContextFetcher().fetch(for: incident)
        let enriched = ctx.isEmpty ? incident : Incident(
            labels:      incident.labels,
            annotations: incident.annotations,
            startsAt:    incident.startsAt,
            k8sContext:  ctx
        )

        let analysis   = try await Analyzer().run(enriched)
        let hypothesis = try await HypothesisAgent().run(enriched, analysis)
        let critique   = try await CriticAgent().run(enriched, hypothesis)
        let fix        = try await FixAgent().run(enriched, critique)
        let risk       = try await RiskAgent().run(enriched, fix)
        return IncidentReport(
            incident:   enriched,
            analysis:   analysis,
            hypothesis: hypothesis,
            fix:        fix,
            risk:       risk
        )
    }
}

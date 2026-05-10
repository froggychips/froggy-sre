/// Пятиэтапный пайплайн анализа инцидентов.
/// Обогащает инцидент живым k8s-контекстом перед первым агентом,
/// затем передаёт похожие прошлые инциденты в Hypothesis-агент.
public actor AgentPipeline {
    private let store: IncidentStore
    private let llm: any LLMCompleting

    public init(llm: any LLMCompleting = LLMRouter(), store: IncidentStore = IncidentStore()) {
        self.llm   = llm
        self.store = store
    }

    public func process(_ incident: Incident) async throws -> IncidentReport {
        let ctx      = await K8sContextFetcher().fetch(for: incident)
        let enriched = ctx.isEmpty ? incident : Incident(
            labels:      incident.labels,
            annotations: incident.annotations,
            startsAt:    incident.startsAt,
            k8sContext:  ctx
        )

        let analysis = try await Analyzer(llm: llm).run(enriched)
        try guardOutput(analysis.summary, stage: "Analyzer")

        let similar    = (try? await store.findSimilar(to: enriched)) ?? []
        let hypothesis = try await HypothesisAgent(llm: llm).run(enriched, analysis, similarPast: similar)
        try guardOutput(hypothesis.rootCause, stage: "Hypothesis")

        let critique = try await CriticAgent(llm: llm).run(enriched, hypothesis)
        try guardOutput(critique.notes, stage: "Critic")

        let fix = try await FixAgent(llm: llm).run(enriched, critique)
        try guardOutput(fix.action, stage: "Fix")

        let risk = try await RiskAgent(llm: llm).run(enriched, fix)

        let report = IncidentReport(
            incident:   enriched,
            analysis:   analysis,
            hypothesis: hypothesis,
            fix:        fix,
            risk:       risk
        )
        try? await store.save(report)
        return report
    }

    // MARK: - Private

    private func guardOutput(_ text: String, stage: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 30 else {
            throw PipelineStageError(stage: stage, reason: "output too short (\(trimmed.count) chars)")
        }
        let lower    = trimmed.lowercased()
        let refusals = ["i cannot", "i'm unable", "i don't have access", "as an ai,", "as an ai assistant"]
        if refusals.contains(where: { lower.hasPrefix($0) }) {
            throw PipelineStageError(stage: stage, reason: "LLM refused: \(String(trimmed.prefix(80)))")
        }
    }
}

public struct PipelineStageError: Error, LocalizedError, Sendable {
    public let stage: String
    public let reason: String
    public var errorDescription: String? { "pipeline stage '\(stage)' failed: \(reason)" }
}

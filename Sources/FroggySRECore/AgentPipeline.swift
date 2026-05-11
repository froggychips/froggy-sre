import Foundation

/// Called after each pipeline stage with stage name, elapsed time, and first 300 chars of output.
public typealias StageProgressHandler = @Sendable (_ stage: String, _ duration: Duration, _ output: String) async -> Void

/// Пятиэтапный пайплайн анализа инцидентов.
/// Обогащает инцидент живым k8s-контекстом перед первым агентом,
/// затем передаёт похожие прошлые инциденты в Hypothesis-агент.
public actor AgentPipeline {
    private let store: IncidentStore
    private let llm: any LLMCompleting
    private let onStage: StageProgressHandler?

    public init(llm: any LLMCompleting = LLMRouter(), store: IncidentStore = IncidentStore(), onStage: StageProgressHandler? = nil) {
        self.llm     = llm
        self.store   = store
        self.onStage = onStage
    }

    public func process(_ incident: Incident) async throws -> IncidentReport {
        // Skip live fetch when context is already embedded (bench / frozen snapshot mode).
        let ctx: K8sContext
        if let existing = incident.k8sContext, !existing.isEmpty {
            ctx = existing
        } else {
            ctx = await K8sContextFetcher().fetch(for: incident)
        }
        let enriched = ctx.isEmpty ? incident : Incident(
            labels:      incident.labels,
            annotations: incident.annotations,
            startsAt:    incident.startsAt,
            k8sContext:  ctx
        )

        var traces: [StageTrace] = []

        let (analysis, analysisTrace) = try await runStage("analyzer") {
            try await Analyzer(llm: llm).run(enriched)
        }
        try guardOutput(analysis.summary, stage: "Analyzer")
        await emit("analyzer", .milliseconds(analysisTrace.durationMs), analysis.summary)
        traces.append(analysisTrace)

        let similar = (try? await store.findSimilar(to: enriched)) ?? []
        let (hypothesis, hypothesisTrace) = try await runStage("hypothesis") {
            try await HypothesisAgent(llm: llm).run(enriched, analysis, similarPast: similar)
        }
        try guardOutput(hypothesis.rootCause, stage: "Hypothesis")
        await emit("hypothesis", .milliseconds(hypothesisTrace.durationMs), hypothesis.rootCause)
        traces.append(hypothesisTrace)

        let (critique, critiqueTrace) = try await runStage("critic") {
            try await CriticAgent(llm: llm).run(enriched, hypothesis)
        }
        try guardOutput(critique.notes, stage: "Critic")
        await emit("critic", .milliseconds(critiqueTrace.durationMs), critique.notes)
        traces.append(critiqueTrace)

        let (fix, fixTrace) = try await runStage("fix") {
            try await FixAgent(llm: llm).run(enriched, critique)
        }
        try guardOutput(fix.action, stage: "Fix")
        await emit("fix", .milliseconds(fixTrace.durationMs), fix.action)
        traces.append(fixTrace)

        let (risk, riskTrace) = try await runStage("risk") {
            try await RiskAgent(llm: llm).run(enriched, fix)
        }
        await emit("risk", .milliseconds(riskTrace.durationMs), risk.rationale)
        traces.append(riskTrace)

        let report = IncidentReport(
            incident:   enriched,
            analysis:   analysis,
            hypothesis: hypothesis,
            critique:   critique,
            fix:        fix,
            risk:       risk,
            trace:      traces
        )
        try? await store.save(report)
        return report
    }

    // MARK: - Private

    /// Runs one pipeline stage, capturing duration and LLM call metadata into a `StageTrace`.
    ///
    /// LLM metadata is collected via a task-local recorder bound for the duration of `body`.
    /// Mock LLM implementations that don't touch `LLMRouter` simply yield empty `llmCalls`.
    private func runStage<T: Sendable>(
        _ stage: String,
        body: @Sendable () async throws -> T
    ) async throws -> (T, StageTrace) {
        let recorder = LLMTraceRecorder()
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await LLMRouter.$recorder.withValue(recorder, operation: body)
        let dur = durationMs(clock.now - start)
        let calls = await recorder.snapshot()
        return (result, StageTrace(stage: stage, durationMs: dur, llmCalls: calls))
    }

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

    private func emit(_ stage: String, _ duration: Duration, _ output: String) async {
        guard let h = onStage else { return }
        await h(stage, duration, String(output.prefix(300)))
    }
}

public struct PipelineStageError: Error, LocalizedError, Sendable {
    public let stage: String
    public let reason: String
    public var errorDescription: String? { "pipeline stage '\(stage)' failed: \(reason)" }
}

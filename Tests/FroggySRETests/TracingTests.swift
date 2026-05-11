import Testing
import Foundation
@testable import FroggySRECore

// MARK: - Test fixtures

/// LLM mock that publishes a fake call to the task-local recorder so we can
/// verify pipeline-level trace integration without standing up a real backend.
struct RecordingMockLLM: LLMCompleting {
    let backend: String
    let response: String

    func complete(system: String, user: String) async throws -> String {
        await LLMRouter.recorder?.record(
            .init(backend: backend, durationMs: 7, fallbackUsed: false)
        )
        return response
    }
}

private let validStageOutput = "Pod crashed because the init container ran out of memory during boot."

// MARK: - Tracing model round-trips

@Test func stageTrace_codableRoundTrip() throws {
    let trace = StageTrace(
        stage: "analyzer",
        durationMs: 1234,
        llmCalls: [
            LLMCallInfo(backend: "froggy", durationMs: 800, fallbackUsed: false),
            LLMCallInfo(backend: "anthropic", durationMs: 400, fallbackUsed: true, error: "daemonNotRunning")
        ]
    )
    let data    = try JSONEncoder().encode(trace)
    let decoded = try JSONDecoder().decode(StageTrace.self, from: data)
    #expect(decoded == trace)
}

@Test func llmCallInfo_codableRoundTrip() throws {
    let info    = LLMCallInfo(backend: "lmstudio", durationMs: 250, fallbackUsed: false, error: nil)
    let data    = try JSONEncoder().encode(info)
    let decoded = try JSONDecoder().decode(LLMCallInfo.self, from: data)
    #expect(decoded == info)
}

// MARK: - IncidentReport backward compat

@Test func incidentReport_decodesLegacyJSON_withoutTraceField() throws {
    // JSON shape from a stored incident before P1.1 — no `trace` key.
    let json = #"""
    {
        "incident": {
            "labels": {"alertname": "PodCrashLooping"},
            "annotations": {},
            "startsAt": "2026-01-01T00:00:00Z"
        },
        "analysis":   { "summary": "high restart rate" },
        "hypothesis": { "rootCause": "OOM in init container" },
        "critique":   null,
        "fix":        { "action": "kubectl rollout restart" },
        "risk":       { "score": 0.2, "rationale": "safe" }
    }
    """#
    let decoded = try JSONDecoder().decode(IncidentReport.self, from: Data(json.utf8))
    #expect(decoded.trace == nil)
    #expect(decoded.hypothesis.rootCause == "OOM in init container")
}

@Test func incidentReport_encodesTrace_whenSet() throws {
    let report = IncidentReport(
        incident:   Incident(labels: ["alertname": "X"], annotations: [:], startsAt: "2026-01-01T00:00:00Z"),
        analysis:   Analysis(summary: "s"),
        hypothesis: Hypothesis(rootCause: "r"),
        critique:   nil,
        fix:        Fix(action: "f"),
        risk:       RiskResult(score: 0.1, rationale: "r"),
        trace:      [StageTrace(stage: "analyzer", durationMs: 100, llmCalls: [])]
    )
    let data    = try JSONEncoder().encode(report)
    let string  = String(decoding: data, as: UTF8.self)
    #expect(string.contains("\"trace\""))
    #expect(string.contains("\"analyzer\""))
}

// MARK: - Pipeline trace collection

private func tmpStore() throws -> (IncidentStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("froggy-sre-trace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (IncidentStore(directory: dir, maxAgeDays: 30), dir)
}

private func sampleIncident() -> Incident {
    Incident(
        labels: ["alertname": "PodCrashLooping", "namespace": "ci"],
        annotations: ["summary": "pod restarted"],
        startsAt: "2026-01-01T00:00:00Z",
        k8sContext: K8sContext(podLogs: "x", recentEvents: nil, podDescription: nil)
    )
}

@Test func pipeline_collectsStageTrace_forAllFiveStages() async throws {
    let (store, dir) = try tmpStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let mock = MockLLM(response: """
        \(validStageOutput)
        SCORE: 0.4
        RATIONALE: medium risk
        """)
    let pipeline = AgentPipeline(llm: mock, store: store)

    let report = try await pipeline.process(sampleIncident())

    let trace = try #require(report.trace)
    #expect(trace.count == 5)
    #expect(trace.map(\.stage) == ["analyzer", "hypothesis", "critic", "fix", "risk"])
    for stage in trace {
        #expect(stage.durationMs >= 0)
        // MockLLM doesn't touch the recorder, so llmCalls stays empty for non-recording mocks.
        #expect(stage.llmCalls.isEmpty)
    }
}

@Test func pipeline_traceCapturesLLMCalls_whenLLMRecords() async throws {
    let (store, dir) = try tmpStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let mock = RecordingMockLLM(
        backend: "mock-backend",
        response: """
            \(validStageOutput)
            SCORE: 0.4
            RATIONALE: medium risk
            """
    )
    let pipeline = AgentPipeline(llm: mock, store: store)

    let report = try await pipeline.process(sampleIncident())

    let trace = try #require(report.trace)
    #expect(trace.count == 5)
    for stage in trace {
        #expect(stage.llmCalls.count == 1)
        #expect(stage.llmCalls.first?.backend == "mock-backend")
        #expect(stage.llmCalls.first?.fallbackUsed == false)
    }
}

@Test func pipeline_savedReport_containsTraceJSON() async throws {
    let (store, dir) = try tmpStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let mock = MockLLM(response: """
        \(validStageOutput)
        SCORE: 0.4
        RATIONALE: medium risk
        """)
    let pipeline = AgentPipeline(llm: mock, store: store)
    _ = try await pipeline.process(sampleIncident())

    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    let file = try #require(files.first)
    let raw = try String(contentsOf: file, encoding: .utf8)
    #expect(raw.contains("\"trace\""))
    #expect(raw.contains("\"analyzer\""))
    #expect(raw.contains("\"risk\""))
}

// MARK: - LLMRouter recorder isolation

@Test func llmRouter_recorder_isolatedToTaskLocalScope() async {
    let recorder = LLMTraceRecorder()
    // No binding → record() falls through (no recorder), so outer snapshot stays empty.
    await LLMRouter.recorder?.record(.init(backend: "x", durationMs: 1, fallbackUsed: false))
    #expect(await recorder.snapshot().isEmpty)

    // Bound scope → record reaches our recorder.
    await LLMRouter.$recorder.withValue(recorder) {
        await LLMRouter.recorder?.record(.init(backend: "y", durationMs: 2, fallbackUsed: false))
    }
    let snap = await recorder.snapshot()
    #expect(snap.count == 1)
    #expect(snap.first?.backend == "y")
}

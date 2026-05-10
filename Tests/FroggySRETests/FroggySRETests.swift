import Testing
@testable import FroggySRECore

@Test func pipelineSmoke() async throws {
    let incident = Incident(
        labels: ["alertname": "PodCrashLooping", "namespace": "squad-test"],
        annotations: ["summary": "Pod restarted 5 times in 10m"],
        startsAt: "2026-01-01T00:00:00Z"
    )
    let report = try await AgentPipeline().process(incident)
    #expect(report.incident.labels["alertname"] == "PodCrashLooping")
}

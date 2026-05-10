import Testing
@testable import FroggySRECore

@Test func incidentReportHasAllFields() async throws {
    // Stub agents return immediately without network calls
    let incident = Incident(
        labels: ["alertname": "PodCrashLooping", "namespace": "squad-test"],
        annotations: ["summary": "Pod restarted 5 times in 10m"],
        startsAt: "2026-01-01T00:00:00Z"
    )
    // Only test struct construction — Analyzer.run() requires ANTHROPIC_API_KEY
    let report = IncidentReport(
        incident: incident,
        analysis: Analysis(summary: "test"),
        hypothesis: Hypothesis(rootCause: "test"),
        fix: Fix(action: "test"),
        risk: RiskResult(score: 0.5, rationale: "test")
    )
    #expect(report.incident.labels["alertname"] == "PodCrashLooping")
    #expect(report.risk.score == 0.5)
}

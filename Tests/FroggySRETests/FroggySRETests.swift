import Testing
import Foundation
@testable import FroggySRECore

// MARK: - Incident

@Test func labelString_containsAllLabels() {
    let incident = Incident(
        labels: ["alertname": "PodCrashLooping", "namespace": "prod"],
        annotations: [:],
        startsAt: "2026-01-01T00:00:00Z"
    )
    #expect(incident.labelString.contains("alertname=PodCrashLooping"))
    #expect(incident.labelString.contains("namespace=prod"))
}

@Test func incident_codableRoundTrip() throws {
    let incident = Incident(
        labels: ["alertname": "OOMKilled"],
        annotations: ["summary": "pod OOM"],
        startsAt: "2026-01-01T00:00:00Z",
        k8sContext: K8sContext(podLogs: "log line", recentEvents: nil, podDescription: nil)
    )
    let data = try JSONEncoder().encode(incident)
    let decoded = try JSONDecoder().decode(Incident.self, from: data)
    #expect(decoded.labels == incident.labels)
    #expect(decoded.annotations == incident.annotations)
    #expect(decoded.k8sContext?.podLogs == "log line")
    #expect(decoded.k8sContext?.recentEvents == nil)
}

// MARK: - K8sContext

@Test func k8sContext_isEmpty_allNil() {
    let ctx = K8sContext(podLogs: nil, recentEvents: nil, podDescription: nil)
    #expect(ctx.isEmpty)
}

@Test func k8sContext_isEmpty_falseWhenAnySet() {
    #expect(!K8sContext(podLogs: "x", recentEvents: nil, podDescription: nil).isEmpty)
    #expect(!K8sContext(podLogs: nil, recentEvents: "x", podDescription: nil).isEmpty)
    #expect(!K8sContext(podLogs: nil, recentEvents: nil, podDescription: "x").isEmpty)
}

// MARK: - RiskResult

@Test func riskResult_storesValues() {
    let r = RiskResult(score: 0.75, rationale: "moderate risk")
    #expect(r.score == 0.75)
    #expect(r.rationale == "moderate risk")
}

@Test func riskResult_codableRoundTrip() throws {
    let r = RiskResult(score: 0.3, rationale: "low risk")
    let data = try JSONEncoder().encode(r)
    let decoded = try JSONDecoder().decode(RiskResult.self, from: data)
    #expect(decoded.score == r.score)
    #expect(decoded.rationale == r.rationale)
}

// MARK: - IncidentReport

@Test func incidentReport_allFields() {
    let incident = Incident(
        labels: ["alertname": "PodCrashLooping", "namespace": "squad-test"],
        annotations: ["summary": "Pod restarted 5 times in 10m"],
        startsAt: "2026-01-01T00:00:00Z"
    )
    let report = IncidentReport(
        incident:   incident,
        analysis:   Analysis(summary: "high restart rate"),
        hypothesis: Hypothesis(rootCause: "OOM in init container"),
        fix:        Fix(action: "kubectl rollout restart"),
        risk:       RiskResult(score: 0.2, rationale: "safe rollout")
    )
    #expect(report.incident.labels["alertname"] == "PodCrashLooping")
    #expect(report.hypothesis.rootCause == "OOM in init container")
    #expect(report.risk.score == 0.2)
}

// MARK: - IncidentStore

@Test func incidentStore_saveLoad_roundTrip() throws {
    // Override default directory via env var so we don't pollute ~/.froggy-sre
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("froggy-sre-tests-\(Int(Date().timeIntervalSince1970))")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    setenv("FROGGY_SRE_INCIDENTS_DIR", tmp.path, 1)
    defer { unsetenv("FROGGY_SRE_INCIDENTS_DIR") }

    let store = IncidentStore()
    let report = IncidentReport(
        incident:   Incident(labels: ["alertname": "TestAlert"], annotations: [:], startsAt: "2026-01-01T00:00:00Z"),
        analysis:   Analysis(summary: "test"),
        hypothesis: Hypothesis(rootCause: "test cause"),
        fix:        Fix(action: "test fix"),
        risk:       RiskResult(score: 0.5, rationale: "test")
    )
    try await store.save(report)
    let loaded = try await store.load(limit: 10)
    #expect(loaded.count == 1)
    #expect(loaded[0].report.incident.labels["alertname"] == "TestAlert")
}

@Test func incidentStore_findSimilar_filtersByAlertname() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("froggy-sre-tests-\(Int(Date().timeIntervalSince1970))")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    setenv("FROGGY_SRE_INCIDENTS_DIR", tmp.path, 1)
    defer { unsetenv("FROGGY_SRE_INCIDENTS_DIR") }

    let store = IncidentStore()
    let makeReport = { (alertname: String) in
        IncidentReport(
            incident:   Incident(labels: ["alertname": alertname], annotations: [:], startsAt: "2026-01-01T00:00:00Z"),
            analysis:   Analysis(summary: "s"),
            hypothesis: Hypothesis(rootCause: "r"),
            fix:        Fix(action: "f"),
            risk:       RiskResult(score: 0.1, rationale: "r")
        )
    }
    try await store.save(makeReport("PodCrashLooping"))
    try await store.save(makeReport("PodCrashLooping"))
    try await store.save(makeReport("HighMemory"))

    let target = Incident(labels: ["alertname": "PodCrashLooping"], annotations: [:], startsAt: "now")
    let similar = try await store.findSimilar(to: target)
    #expect(similar.count == 2)
    #expect(similar.allSatisfy { $0.report.incident.labels["alertname"] == "PodCrashLooping" })
}

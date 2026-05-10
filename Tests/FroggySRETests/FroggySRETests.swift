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
    let data    = try JSONEncoder().encode(incident)
    let decoded = try JSONDecoder().decode(Incident.self, from: data)
    #expect(decoded.labels == incident.labels)
    #expect(decoded.annotations == incident.annotations)
    #expect(decoded.k8sContext?.podLogs == "log line")
    #expect(decoded.k8sContext?.recentEvents == nil)
}

// MARK: - K8sContext

@Test func k8sContext_isEmpty_allNil() {
    #expect(K8sContext(podLogs: nil, recentEvents: nil, podDescription: nil).isEmpty)
}

@Test func k8sContext_isEmpty_falseWhenAnySet() {
    #expect(!K8sContext(podLogs: "x",  recentEvents: nil, podDescription: nil).isEmpty)
    #expect(!K8sContext(podLogs: nil,  recentEvents: "x", podDescription: nil).isEmpty)
    #expect(!K8sContext(podLogs: nil,  recentEvents: nil, podDescription: "x").isEmpty)
}

// MARK: - RiskResult

@Test func riskResult_storesValues() {
    let r = RiskResult(score: 0.75, rationale: "moderate risk")
    #expect(r.score == 0.75)
    #expect(r.rationale == "moderate risk")
}

@Test func riskResult_codableRoundTrip() throws {
    let r       = RiskResult(score: 0.3, rationale: "low risk")
    let data    = try JSONEncoder().encode(r)
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

// MARK: - IncidentStore helpers

private func tmpStore(maxAgeDays: Int = 30) throws -> (IncidentStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("froggy-sre-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (IncidentStore(directory: dir, maxAgeDays: maxAgeDays), dir)
}

private func makeReport(alertname: String) -> IncidentReport {
    IncidentReport(
        incident:   Incident(labels: ["alertname": alertname], annotations: [:], startsAt: "2026-01-01T00:00:00Z"),
        analysis:   Analysis(summary: "s"),
        hypothesis: Hypothesis(rootCause: "r"),
        fix:        Fix(action: "f"),
        risk:       RiskResult(score: 0.1, rationale: "r")
    )
}

// MARK: - IncidentStore

@Test func incidentStore_saveLoad_roundTrip() async throws {
    let (store, dir) = try tmpStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try await store.save(makeReport(alertname: "TestAlert"))
    let loaded = try await store.load(limit: 10)
    #expect(loaded.count == 1)
    #expect(loaded[0].report.incident.labels["alertname"] == "TestAlert")
}

@Test func incidentStore_findSimilar_filtersByAlertname() async throws {
    let (store, dir) = try tmpStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    try await store.save(makeReport(alertname: "PodCrashLooping"))
    try await store.save(makeReport(alertname: "PodCrashLooping"))
    try await store.save(makeReport(alertname: "HighMemory"))

    let target  = Incident(labels: ["alertname": "PodCrashLooping"], annotations: [:], startsAt: "now")
    let similar = try await store.findSimilar(to: target)
    #expect(similar.count == 2)
    #expect(similar.allSatisfy { $0.report.incident.labels["alertname"] == "PodCrashLooping" })
}

@Test func incidentStore_findSimilar_respectsLimit() async throws {
    let (store, dir) = try tmpStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    for _ in 0..<5 { try await store.save(makeReport(alertname: "Flood")) }

    let target  = Incident(labels: ["alertname": "Flood"], annotations: [:], startsAt: "now")
    let similar = try await store.findSimilar(to: target, limit: 2)
    #expect(similar.count == 2)
}

@Test func incidentStore_prune_removesOldFiles() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("froggy-sre-prune-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Write a JSON file with creation date 40 days ago
    let oldFile = dir.appendingPathComponent("old-incident.json")
    try "{}".write(to: oldFile, atomically: true, encoding: .utf8)
    let pastDate = Date().addingTimeInterval(-40 * 86_400)
    try (oldFile as NSURL).setResourceValue(pastDate, forKey: .creationDateKey)

    // Store with maxAgeDays=30 — saving any report should trigger prune
    let store = IncidentStore(directory: dir, maxAgeDays: 30)
    try await store.save(makeReport(alertname: "Trigger"))

    let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(!remaining.contains("old-incident.json"), "old file should have been pruned")
    #expect(remaining.count == 1, "only the new incident file should remain")
}

// MARK: - K8sFacts.peerNamespace

@Test func peerNamespace_squadOne_returnSquadTwo() {
    #expect(K8sFacts.peerNamespace("squad-1-kingdom2") == "squad-2-kingdom2")
}

@Test func peerNamespace_squadTwo_returnsSquadThree() {
    #expect(K8sFacts.peerNamespace("squad-2-shared") == "squad-3-shared")
}

@Test func peerNamespace_squadThree_returnsSquadTwo() {
    #expect(K8sFacts.peerNamespace("squad-3-auth") == "squad-2-auth")
}

@Test func peerNamespace_nonSquad_returnsNil() {
    #expect(K8sFacts.peerNamespace("prod")        == nil)
    #expect(K8sFacts.peerNamespace("preprod")     == nil)
    #expect(K8sFacts.peerNamespace("kube-system") == nil)
    #expect(K8sFacts.peerNamespace("mcp")         == nil)
}

@Test func peerNamespace_squadNoSuffix_returnsNil() {
    // "squad-1" has no trailing "-suffix" so should not match
    #expect(K8sFacts.peerNamespace("squad-1") == nil)
}

import Testing
import Foundation
@testable import FroggySRECore

// MARK: - MockLLM

struct MockLLM: LLMCompleting {
    let response: String
    func complete(system: String, user: String) async throws -> String { response }
}

struct FailingLLM: LLMCompleting {
    struct Fail: Error {}
    func complete(system: String, user: String) async throws -> String { throw Fail() }
}

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
        critique:   nil,
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
        critique:   nil,
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

    let oldFile = dir.appendingPathComponent("old-incident.json")
    try "{}".write(to: oldFile, atomically: true, encoding: .utf8)
    let pastDate = Date().addingTimeInterval(-40 * 86_400)
    try (oldFile as NSURL).setResourceValue(pastDate, forKey: .creationDateKey)

    let store = IncidentStore(directory: dir, maxAgeDays: 30)
    try await store.save(makeReport(alertname: "Trigger"))

    let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(!remaining.contains("old-incident.json"), "старый файл должен быть удалён prune()")
    #expect(remaining.count == 1, "должен остаться только новый инцидент")
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
    #expect(K8sFacts.peerNamespace("squad-1") == nil)
}

// MARK: - AgentPipeline smoke test (MockLLM — без реального LLM)

private func crashLoopIncident() -> Incident {
    Incident(
        labels: ["alertname": "PodCrashLooping", "namespace": "squad-1-payments", "pod": "api-7f9b"],
        annotations: ["summary": "Pod restarted 8 times in 15 minutes"],
        startsAt: "2026-05-10T12:00:00Z"
    )
}

@Test func pipeline_smoke_withMockLLM_producesFullReport() async throws {
    let mock = MockLLM(response: "SCORE: 0.3\nRATIONALE: Low risk, pod restart is safe.")
    let pipeline = AgentPipeline(llm: mock)
    let report = try await pipeline.process(crashLoopIncident())

    #expect(!report.analysis.summary.isEmpty)
    #expect(!report.hypothesis.rootCause.isEmpty)
    #expect(!report.fix.action.isEmpty)
    #expect(report.risk.score >= 0.0 && report.risk.score <= 1.0)
    #expect(report.incident.labels["alertname"] == "PodCrashLooping")
}

@Test func pipeline_smoke_savesReportToStore() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("froggy-sre-pipeline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let mock     = MockLLM(response: "SCORE: 0.2\nRATIONALE: Safe operation.")
    let store    = IncidentStore(directory: dir)
    let pipeline = AgentPipeline(llm: mock, store: store)
    _ = try await pipeline.process(crashLoopIncident())

    let saved = try await store.load(limit: 5)
    #expect(saved.count == 1)
    #expect(saved[0].report.incident.labels["alertname"] == "PodCrashLooping")
}

// MARK: - guardOutput (через PipelineStageError)

@Test func pipeline_guardOutput_throwsOnEmptyResponse() async throws {
    let mock     = MockLLM(response: "")
    let pipeline = AgentPipeline(llm: mock)
    do {
        _ = try await pipeline.process(crashLoopIncident())
        Issue.record("ожидался PipelineStageError, но pipeline прошёл")
    } catch let e as PipelineStageError {
        #expect(e.stage == "Analyzer")
        #expect(e.reason.contains("too short"))
    }
}

@Test func pipeline_guardOutput_throwsOnRefusal() async throws {
    let mock     = MockLLM(response: "I cannot help with this request because it involves infrastructure.")
    let pipeline = AgentPipeline(llm: mock)
    do {
        _ = try await pipeline.process(crashLoopIncident())
        Issue.record("ожидался PipelineStageError, но pipeline прошёл")
    } catch let e as PipelineStageError {
        #expect(e.stage == "Analyzer")
        #expect(e.reason.contains("refused"))
    }
}

// MARK: - AnthropicClient retry

/// URLProtocol stub: replays a pre-configured sequence of (statusCode, body) pairs.
/// Tests that use this must run serially — see AnthropicRetryTests suite below.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var queue: [(Int, Data)] = []
    nonisolated(unsafe) static var callCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let idx = Self.callCount
        Self.callCount += 1
        let (code, body) = Self.queue[idx]
        let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                   httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func anthropicSuccessBody(text: String) -> Data {
    let json = ["content": [["type": "text", "text": text]]]
    return try! JSONSerialization.data(withJSONObject: json)
}

@Suite(.serialized)
struct AnthropicRetryTests {
    @Test func retries_on429_succeeds_eventually() async throws {
        StubURLProtocol.queue     = [(429, Data()), (429, Data()), (200, anthropicSuccessBody(text: "ok"))]
        StubURLProtocol.callCount = 0

        let client = AnthropicClient(apiKey: "test-key", session: stubSession(), retryBaseDelay: 0.001)
        let result = try await client.complete(system: "s", user: "u")

        #expect(result == "ok")
        #expect(StubURLProtocol.callCount == 3)
    }

    @Test func exhaustedRetries_throws() async throws {
        StubURLProtocol.queue     = [(429, Data()), (429, Data()), (429, Data()), (429, Data())]
        StubURLProtocol.callCount = 0

        let client = AnthropicClient(apiKey: "test-key", session: stubSession(), retryBaseDelay: 0.001)
        do {
            _ = try await client.complete(system: "s", user: "u")
            Issue.record("expected throw")
        } catch AnthropicError.httpError(let code) {
            #expect(code == 429)
            #expect(StubURLProtocol.callCount == 4)
        }
    }
}

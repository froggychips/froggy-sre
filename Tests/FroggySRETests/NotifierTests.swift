import Testing
import Foundation
@testable import FroggySRECore

// MARK: - URLProtocol stub for capturing HTTP requests in-process

/// Lightweight URLProtocol shim — captures the request and returns a
/// preset HTTP response without ever touching the network.
final class HTTPStub: URLProtocol, @unchecked Sendable {
    /// Stored under a lock so parallel-running tests don't trample each other.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var _captured: [URLRequest] = []

    static func install(_ handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
        _captured = []
    }

    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _captured = []
    }

    static func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self._handler
        Self._captured.append(request)
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStub.self]
    return URLSession(configuration: config)
}

private func sampleReport(score: Double, alertname: String = "PodCrashLooping") -> IncidentReport {
    IncidentReport(
        incident:   Incident(labels: ["alertname": alertname, "namespace": "ci"], annotations: [:], startsAt: "2026-05-11T00:00:00Z"),
        analysis:   Analysis(summary: "high restart rate"),
        hypothesis: Hypothesis(rootCause: "OOM in init container"),
        critique:   nil,
        fix:        Fix(action: "kubectl rollout restart"),
        risk:       RiskResult(score: score, rationale: "moderate impact")
    )
}

// MARK: - Payload shape

@Test func notifierPayload_codableRoundTrip() throws {
    let payload = NotifierPayload(
        text: "[CRITICAL] X — risk 0.85",
        attachments: [
            .init(color: "danger", title: "X", fields: [
                .init(title: "Root cause", value: "rc", short: false),
                .init(title: "Risk",       value: "0.85 — r", short: true),
            ])
        ]
    )
    let data    = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(NotifierPayload.self, from: data)
    #expect(decoded == payload)
}

@Test func makePayload_includesAlertnameAndScoreInText() {
    let report = sampleReport(score: 0.85, alertname: "OOMKilled")
    let payload = NotifierClient.makePayload(from: report)
    #expect(payload.text.contains("OOMKilled"))
    #expect(payload.text.contains("0.85"))
    #expect(payload.text.hasPrefix("[CRITICAL]"))
}

@Test func makePayload_attachmentColorIsDanger() {
    let payload = NotifierClient.makePayload(from: sampleReport(score: 0.9))
    #expect(payload.attachments.first?.color == "danger")
    #expect(payload.attachments.first?.fields.count == 4)
    #expect(payload.attachments.first?.fields.contains(where: { $0.title == "Root cause" }) == true)
    #expect(payload.attachments.first?.fields.contains(where: { $0.title == "Proposed fix" }) == true)
    #expect(payload.attachments.first?.fields.contains(where: { $0.title == "Risk" }) == true)
    #expect(payload.attachments.first?.fields.contains(where: { $0.title == "Namespace" }) == true)
}

// MARK: - notifyIfCritical behavior

@Test func notifier_noOp_whenWebhookMissing() async {
    let notifier = NotifierClient(webhookURL: nil, threshold: 0.5, session: stubbedSession())
    let attempted = await notifier.notifyIfCritical(sampleReport(score: 0.9))
    #expect(attempted == false)
}

@Test func notifier_noOp_whenScoreBelowThreshold() async {
    HTTPStub.install { req in
        let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data())
    }
    // intentionally no uninstall — leaks across parallel tests would be benign now that
    // every test filters captured by its own unique URL.

    let url = URL(string: "https://hooks.test.invalid/below-\(UUID().uuidString)")!
    let notifier = NotifierClient(webhookURL: url, threshold: 0.7, session: stubbedSession())
    let attempted = await notifier.notifyIfCritical(sampleReport(score: 0.3))
    #expect(attempted == false)
    #expect(HTTPStub.captured().contains { $0.url == url } == false)
}

@Test func notifier_posts_whenScoreAtOrAboveThreshold() async throws {
    HTTPStub.install { req in
        let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data())
    }

    let url = URL(string: "https://hooks.test.invalid/posts-\(UUID().uuidString)")!
    let notifier = NotifierClient(webhookURL: url, threshold: 0.7, session: stubbedSession())
    let attempted = await notifier.notifyIfCritical(sampleReport(score: 0.85, alertname: "DBSlowQuery"))
    #expect(attempted == true)

    let captured = HTTPStub.captured().filter { $0.url == url }
    let request = try #require(captured.first)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    // URLProtocol delivers httpBody via httpBodyStream when going through
    // the URLSession data pipeline. Read it explicitly.
    let bodyData: Data
    if let direct = request.httpBody {
        bodyData = direct
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var collected = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 4096)
            if n <= 0 { break }
            collected.append(buf, count: n)
        }
        bodyData = collected
    } else {
        Issue.record("no httpBody or httpBodyStream on request")
        return
    }

    let payload = try JSONDecoder().decode(NotifierPayload.self, from: bodyData)
    #expect(payload.text.contains("DBSlowQuery"))
    #expect(payload.text.contains("0.85"))
    #expect(payload.attachments.first?.fields.contains(where: { $0.value.contains("OOM in init container") }) == true)
}

@Test func notifier_treatsScoreEqualToThreshold_asTrigger() async {
    HTTPStub.install { req in
        let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data())
    }

    let url = URL(string: "https://hooks.test.invalid/eq-\(UUID().uuidString)")!
    let notifier = NotifierClient(webhookURL: url, threshold: 0.7, session: stubbedSession())
    let attempted = await notifier.notifyIfCritical(sampleReport(score: 0.7))
    #expect(attempted == true)
    #expect(HTTPStub.captured().filter { $0.url == url }.count == 1)
}

@Test func notifier_swallowsServer5xx_returnsTrueAnyway() async {
    // 5xx response handler scoped to this test's URL only. The HTTPStub
    // matches by request, but here we just install a 500-responder; other
    // tests with their own URLs were installed too, last-write-wins by design.
    HTTPStub.install { req in
        let r = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (r, Data("oops".utf8))
    }

    let url = URL(string: "https://hooks.test.invalid/5xx-\(UUID().uuidString)")!
    let notifier = NotifierClient(webhookURL: url, threshold: 0.5, session: stubbedSession())
    let attempted = await notifier.notifyIfCritical(sampleReport(score: 0.9))
    // 5xx is logged as error but does not crash the daemon — attempted=true means we tried.
    #expect(attempted == true)
}

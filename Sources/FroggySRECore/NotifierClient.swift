import Foundation
import os

/// Opt-in webhook notifier for critical incidents.
///
/// Triggers a POST to `FROGGY_SRE_NOTIFY_WEBHOOK` (if set) when
/// `report.risk.score >= FROGGY_SRE_NOTIFY_THRESHOLD` (default 0.7).
/// Payload is generic JSON but shaped to be Slack-compatible:
///
/// ```json
/// {
///   "text": "[CRITICAL] <alertname> — risk 0.85",
///   "attachments": [{
///     "color": "danger",
///     "title": "<alertname>",
///     "fields": [
///       { "title": "Root cause", "value": "<hypothesis>", "short": false },
///       { "title": "Proposed fix", "value": "<fix>", "short": false },
///       { "title": "Risk", "value": "0.85 — <rationale>", "short": true },
///       { "title": "Namespace", "value": "...", "short": true }
///     ]
///   }]
/// }
/// ```
///
/// Slack/Mattermost accept this shape directly. Discord and generic
/// webhooks read the top-level `text` field and ignore `attachments`.
public struct NotifierClient: Sendable {
    public let webhookURL: URL?
    public let threshold: Double
    private let session: URLSession

    private static let logger = Logger(subsystem: "froggychips.froggy-sre", category: "notifier")

    /// Reads `FROGGY_SRE_NOTIFY_WEBHOOK` and `FROGGY_SRE_NOTIFY_THRESHOLD` from the
    /// environment. If the webhook is absent or malformed, the notifier becomes
    /// a no-op — `notifyIfCritical` returns without doing anything.
    public init(session: URLSession = .shared) {
        let env = ProcessInfo.processInfo.environment
        self.webhookURL = env["FROGGY_SRE_NOTIFY_WEBHOOK"].flatMap(URL.init(string:))
        self.threshold = env["FROGGY_SRE_NOTIFY_THRESHOLD"].flatMap(Double.init) ?? 0.7
        self.session = session
    }

    /// Explicit init for tests and embedded use.
    public init(webhookURL: URL?, threshold: Double = 0.7, session: URLSession = .shared) {
        self.webhookURL = webhookURL
        self.threshold = threshold
        self.session = session
    }

    /// Fire-and-forget: posts the report if it meets the threshold. Returns
    /// `true` if a POST was attempted (successfully or not), `false` if the
    /// notifier was a no-op (no URL, score below threshold).
    @discardableResult
    public func notifyIfCritical(_ report: IncidentReport) async -> Bool {
        guard let url = webhookURL else { return false }
        guard report.risk.score >= threshold else { return false }

        let payload = Self.makePayload(from: report)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    Self.logger.debug("webhook ok status=\(http.statusCode) alert=\(report.incident.labels["alertname", default: "?"], privacy: .public)")
                } else {
                    Self.logger.error("webhook non-2xx status=\(http.statusCode) host=\(url.host ?? "?", privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("webhook error host=\(url.host ?? "?", privacy: .public) reason=\(String(describing: error), privacy: .public)")
        }
        return true
    }

    // MARK: - Payload shape

    static func makePayload(from report: IncidentReport) -> NotifierPayload {
        let alertname = report.incident.labels["alertname"] ?? "unknown alert"
        let namespace = report.incident.labels["namespace"] ?? "—"
        let scoreStr = String(format: "%.2f", report.risk.score)

        let summary = "[CRITICAL] \(alertname) — risk \(scoreStr)"

        let fields: [NotifierPayload.Attachment.Field] = [
            .init(title: "Root cause",   value: clip(report.hypothesis.rootCause), short: false),
            .init(title: "Proposed fix", value: clip(report.fix.action),            short: false),
            .init(title: "Risk",         value: "\(scoreStr) — \(clip(report.risk.rationale, max: 200))", short: true),
            .init(title: "Namespace",    value: namespace,                          short: true),
        ]

        return NotifierPayload(
            text: summary,
            attachments: [
                .init(color: "danger", title: alertname, fields: fields)
            ]
        )
    }

    private static func clip(_ s: String, max: Int = 500) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}

// MARK: - Wire shape (public for testing and external consumers)

public struct NotifierPayload: Codable, Sendable, Equatable {
    public let text: String
    public let attachments: [Attachment]

    public struct Attachment: Codable, Sendable, Equatable {
        public let color: String
        public let title: String
        public let fields: [Field]

        public struct Field: Codable, Sendable, Equatable {
            public let title: String
            public let value: String
            public let short: Bool

            public init(title: String, value: String, short: Bool) {
                self.title = title
                self.value = value
                self.short = short
            }
        }

        public init(color: String, title: String, fields: [Field]) {
            self.color = color
            self.title = title
            self.fields = fields
        }
    }

    public init(text: String, attachments: [Attachment]) {
        self.text = text
        self.attachments = attachments
    }
}

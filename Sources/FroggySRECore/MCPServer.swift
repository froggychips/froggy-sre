import Foundation

/// JSON-RPC 2.0 stdio MCP server.
/// Follows the same transport pattern as froggy-mcp.
public actor MCPServer {
    private let pipeline: AgentPipeline
    private let store: IncidentStore

    public init() {
        pipeline = AgentPipeline()
        store    = IncidentStore()
    }

    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let msg  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String
            else { continue }

            if method.hasPrefix("notifications/") { continue }

            let id     = msg["id"]
            let params = msg["params"] as? [String: Any]
            let result = await dispatch(method: method, params: params)
            send(id: id, result: result)
        }
    }

    // MARK: - Dispatch

    private func dispatch(method: String, params: [String: Any]?) async -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "froggy-sre", "version": "0.1.0"]
            ] as [String: Any]
        case "tools/list":
            return ["tools": toolList()] as [String: Any]
        case "tools/call":
            guard let name = params?["name"] as? String else { return errorContent("missing tool name") }
            return await handleCall(name: name, args: params?["arguments"] as? [String: Any] ?? [:])
        default:
            return errorContent("unknown method: \(method)")
        }
    }

    private func handleCall(name: String, args: [String: Any]) async -> [String: Any] {
        switch name {
        case "sre_analyze": return await analyzeTool(args: args)
        case "sre_history": return await historyTool(args: args)
        default:            return errorContent("unknown tool: \(name)")
        }
    }

    // MARK: - sre_analyze

    private func analyzeTool(args: [String: Any]) async -> [String: Any] {
        let incident = Incident(
            labels:      args["labels"]      as? [String: String] ?? [:],
            annotations: args["annotations"] as? [String: String] ?? [:],
            startsAt:    args["startsAt"]    as? String ?? ""
        )
        do {
            let report = try await pipeline.process(incident)
            try? await store.save(report)
            return textContent(format(report))
        } catch {
            return errorContent("analysis failed: \(error)")
        }
    }

    // MARK: - sre_history

    private func historyTool(args: [String: Any]) async -> [String: Any] {
        let limit = args["limit"] as? Int ?? 10
        do {
            let incidents = try await store.load(limit: limit)
            guard !incidents.isEmpty else { return textContent("No incidents recorded yet.") }
            return textContent(incidents.enumerated().map { i, s in formatStored(index: i + 1, stored: s) }.joined(separator: "\n\n"))
        } catch {
            return errorContent("failed to load history: \(error)")
        }
    }

    // MARK: - Tool list

    private func toolList() -> [[String: Any]] {
        [
            [
                "name": "sre_analyze",
                "description": "Analyze a Kubernetes incident through the 5-stage pipeline. Automatically fetches pod logs and k8s events via kubectl. Result is saved to incident history.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "labels":      ["type": "object", "description": "Alert labels (alertname, namespace, pod, severity, …)", "additionalProperties": ["type": "string"]],
                        "annotations": ["type": "object", "description": "Alert annotations (summary, description, runbook, …)", "additionalProperties": ["type": "string"]],
                        "startsAt":    ["type": "string",  "description": "ISO 8601 timestamp when the alert fired"]
                    ],
                    "required": ["labels"]
                ]
            ],
            [
                "name": "sre_history",
                "description": "Return recent incident analysis reports saved on this machine.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max incidents to return (default: 10)"]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Formatting

    private func format(_ r: IncidentReport) -> String {
        var ctxNote = ""
        if let ctx = r.incident.k8sContext, !ctx.isEmpty {
            var sources: [String] = []
            if ctx.podLogs        != nil { sources.append("pod logs") }
            if ctx.recentEvents   != nil { sources.append("k8s events") }
            if ctx.podDescription != nil { sources.append("pod description") }
            ctxNote = "\n> Context fetched: \(sources.joined(separator: ", "))\n"
        }
        return """
        ## SRE Incident Analysis
        \(ctxNote)
        ### What’s happening
        \(r.analysis.summary)

        ### Root cause hypothesis
        \(r.hypothesis.rootCause)

        ### Proposed fix
        \(r.fix.action)

        ### Risk
        Score: \(String(format: "%.2f", r.risk.score))/1.0
        \(r.risk.rationale)
        """
    }

    private func formatStored(index: Int, stored: StoredIncident) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let ts        = fmt.string(from: stored.timestamp)
        let alert     = stored.report.incident.labels["alertname"] ?? "unknown"
        let namespace = stored.report.incident.labels["namespace"].map { " (\($0))" } ?? ""
        let score     = String(format: "%.2f", stored.report.risk.score)
        let hasCtx    = stored.report.incident.k8sContext.map { !$0.isEmpty } ?? false
        return """
        \(index). \(ts) — \(alert)\(namespace) — Risk: \(score)\(hasCtx ? " [k8s ctx]" : "")
           \(clip(stored.report.analysis.summary, 120))
           Fix: \(clip(stored.report.fix.action, 100))
        """
    }

    private func clip(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }

    // MARK: - Transport

    private func send(id: Any?, result: Any) {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let str  = String(data: data, encoding: .utf8) else { return }
        print(str)
        fflush(stdout)
    }

    private func textContent(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private func errorContent(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }
}

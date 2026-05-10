import Foundation

/// JSON-RPC 2.0 stdio MCP server.
/// Follows the same transport pattern as froggy-mcp.
///
/// MCP mode: collects anamnesis (local model) → returns to Claude for reasoning.
/// Daemon mode (SREDaemon): runs the full 5-agent pipeline autonomously.
public actor MCPServer {
    private let store: IncidentStore

    public init() {
        store = IncidentStore()
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
    //
    // Collects live k8s data + local-model anamnesis, then returns everything
    // to Claude for reasoning. Claude IS the diagnosis layer in MCP mode.

    private func analyzeTool(args: [String: Any]) async -> [String: Any] {
        let incident = Incident(
            labels:      args["labels"]      as? [String: String] ?? [:],
            annotations: args["annotations"] as? [String: String] ?? [:],
            startsAt:    args["startsAt"]    as? String ?? ""
        )
        let ctx      = await K8sContextFetcher().fetch(for: incident)
        let enriched = ctx.isEmpty ? incident : Incident(
            labels:      incident.labels,
            annotations: incident.annotations,
            startsAt:    incident.startsAt,
            k8sContext:  ctx
        )
        let anamnesis = await AnamnesisCollector().collect(incident: enriched, context: ctx)

        // Persist to history so sre_history can surface past similar cases.
        let record = IncidentReport(
            incident:   enriched,
            analysis:   Analysis(summary: anamnesis),
            hypothesis: Hypothesis(rootCause: "(pending — Claude)"),
            fix:        Fix(action: "(pending — Claude)"),
            risk:       RiskResult(score: -1, rationale: "(pending — Claude)")
        )
        try? await store.save(record)

        return textContent(anamnesis)
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
                "description": """
                Fetch live Kubernetes context for an incident and return a structured anamnesis.
                Automatically runs kubectl to collect pod logs, warning events, and pod description.
                A local model extracts key facts (exit codes, error types, restart timing).
                Returns all data for you to analyze — you are the diagnosis layer.
                """,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "labels":      ["type": "object", "description": "Alert labels. Include \"namespace\" and \"pod\" for kubectl enrichment.", "additionalProperties": ["type": "string"]],
                        "annotations": ["type": "object", "description": "Alert annotations (summary, description, runbook, …)", "additionalProperties": ["type": "string"]],
                        "startsAt":    ["type": "string",  "description": "ISO 8601 timestamp when the alert fired"]
                    ],
                    "required": ["labels"]
                ]
            ],
            [
                "name": "sre_history",
                "description": "Return recent incidents collected on this machine. Useful for spotting recurring patterns.",
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

    private func formatStored(index: Int, stored: StoredIncident) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let ts        = fmt.string(from: stored.timestamp)
        let alert     = stored.report.incident.labels["alertname"] ?? "unknown"
        let namespace = stored.report.incident.labels["namespace"].map { " (\($0))" } ?? ""
        let hasCtx    = stored.report.incident.k8sContext.map { !$0.isEmpty } ?? false
        return """
        \(index). \(ts) — \(alert)\(namespace)\(hasCtx ? " [k8s ctx]" : "")
           \(clip(stored.report.analysis.summary, 200))
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

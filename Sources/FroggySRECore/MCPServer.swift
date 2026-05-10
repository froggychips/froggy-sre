import Foundation

/// JSON-RPC 2.0 stdio MCP server.
/// Follows the same transport pattern as froggy-mcp.
public actor MCPServer {
    private let pipeline: AgentPipeline

    public init() {
        pipeline = AgentPipeline()
    }

    public func run() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = msg["method"] as? String
            else { continue }

            // Notifications carry no id and expect no response
            if method.hasPrefix("notifications/") { continue }

            let id = msg["id"]
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
            guard let name = params?["name"] as? String else {
                return errorContent("missing tool name")
            }
            let args = params?["arguments"] as? [String: Any] ?? [:]
            return await handleCall(name: name, args: args)

        default:
            return errorContent("unknown method: \(method)")
        }
    }

    private func handleCall(name: String, args: [String: Any]) async -> [String: Any] {
        switch name {
        case "sre_analyze":
            return await analyzeTool(args: args)
        default:
            return errorContent("unknown tool: \(name)")
        }
    }

    // MARK: - Tools

    private func analyzeTool(args: [String: Any]) async -> [String: Any] {
        let labels      = args["labels"]      as? [String: String] ?? [:]
        let annotations = args["annotations"] as? [String: String] ?? [:]
        let startsAt    = args["startsAt"]    as? String ?? ""

        let incident = Incident(labels: labels, annotations: annotations, startsAt: startsAt)
        do {
            let report = try await pipeline.process(incident)
            return textContent(format(report))
        } catch {
            return errorContent("analysis failed: \(error)")
        }
    }

    private func toolList() -> [[String: Any]] {
        [[
            "name": "sre_analyze",
            "description": "Analyze a Kubernetes incident through the 5-stage pipeline: Analyzer → Hypothesis → Critic → Fix → Risk. Returns risk score and remediation guidance.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "labels": [
                        "type": "object",
                        "description": "Alert labels — alertname, namespace, pod, severity, etc.",
                        "additionalProperties": ["type": "string"]
                    ],
                    "annotations": [
                        "type": "object",
                        "description": "Alert annotations — summary, description, runbook, etc.",
                        "additionalProperties": ["type": "string"]
                    ],
                    "startsAt": [
                        "type": "string",
                        "description": "ISO 8601 timestamp when the alert fired"
                    ]
                ],
                "required": ["labels"]
            ]
        ]]
    }

    // MARK: - Helpers

    private func send(id: Any?, result: Any) {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let str = String(data: data, encoding: .utf8) else { return }
        print(str)
        fflush(stdout)
    }

    private func textContent(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private func errorContent(_ msg: String) -> [String: Any] {
        ["content": [["type": "text", "text": "Error: \(msg)"]], "isError": true]
    }

    private func format(_ report: IncidentReport) -> String {
        """
        ## SRE Incident Analysis

        ### What's happening
        \(report.analysis.summary)

        ### Root cause hypothesis
        \(report.hypothesis.rootCause)

        ### Proposed fix
        \(report.fix.action)

        ### Risk
        Score: \(String(format: "%.2f", report.risk.score))/1.0
        \(report.risk.rationale)
        """
    }
}

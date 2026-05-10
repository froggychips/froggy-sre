import Foundation

public struct K8sContext: Sendable, Codable {
    public let podLogs: String?
    public let recentEvents: String?
    public let podDescription: String?

    public var isEmpty: Bool {
        podLogs == nil && recentEvents == nil && podDescription == nil
    }
}

/// Fetches live k8s observability data via kubectl before the agent pipeline runs.
/// All calls are best-effort — missing kubectl or unknown pod just returns nil fields.
public struct K8sContextFetcher: Sendable {
    public init() {}

    public func fetch(for incident: Incident) async -> K8sContext {
        let ns  = incident.labels["namespace"] ?? ""
        let pod = incident.labels["pod"] ?? incident.labels["pod_name"] ?? ""
        guard !ns.isEmpty else { return K8sContext(podLogs: nil, recentEvents: nil, podDescription: nil) }

        let hasPod = !pod.isEmpty
        // Fetch current + previous container logs: crash evidence lives in --previous when pod is in CrashLoopBackOff.
        let logsNow  = hasPod ? await kubectl(["logs", pod, "-n", ns, "--tail=60", "--all-containers", "--ignore-errors"]) : nil
        let logsPrev = hasPod ? await kubectl(["logs", pod, "-n", ns, "--tail=40", "--previous", "--ignore-errors"]) : nil
        let logs: String? = switch (logsNow, logsPrev) {
            case (let a?, let b?): "=== current ===\n\(a)\n=== previous (crashed) ===\n\(b)"
            case (let a?, nil):    a
            case (nil, let b?):    "=== previous (crashed) ===\n\(b)"
            case (nil, nil):       nil
        }
        let events = await kubectl(["get", "events", "-n", ns, "--sort-by=.lastTimestamp", "--field-selector=type=Warning"])
        let rawDesc = hasPod ? await kubectl(["describe", "pod", pod, "-n", ns]) : nil
        return K8sContext(
            podLogs:        logs,
            recentEvents:   events,
            podDescription: rawDesc.map { clip($0, lines: 60) }
        )
    }

    private func kubectl(_ args: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            Task.detached {
                let proc = Process()
                if let path = ProcessInfo.processInfo.environment["KUBECTL_PATH"] {
                    proc.executableURL = URL(fileURLWithPath: path)
                    proc.arguments     = args
                } else {
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    proc.arguments     = ["kubectl"] + args
                }
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError  = Pipe()
                guard (try? proc.run()) != nil else { continuation.resume(returning: nil); return }
                proc.waitUntilExit()
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text?.isEmpty == false ? text : nil)
            }
        }
    }

    private func clip(_ text: String, lines: Int) -> String {
        let all = text.components(separatedBy: "\n")
        return all.count > lines ? all.prefix(lines).joined(separator: "\n") + "\n…[truncated]" : text
    }
}

import Foundation

/// Collects verified facts from the local kubeconfig for Critic enrichment.
/// Runs kubectl via Process — no external dependencies.
public struct K8sFacts: Sendable {

    public static func collect(namespace: String) async -> String {
        await Task.detached(priority: .utility) {
            collectSync(namespace: namespace)
        }.value
    }

    // MARK: - Private

    private struct PodInfo {
        let name: String
        let phase: String
        let restarts: Int
    }

    private static func collectSync(namespace: String) -> String {
        var lines: [String] = []

        // Fact 1: unhealthy pods in the incident namespace
        if let pods = kubectlGetPods(namespace: namespace) {
            let unhealthy = pods
                .filter { $0.phase != "Running" && $0.phase != "Succeeded" }
                .map { "\($0.name): \($0.phase) restarts=\($0.restarts)" }
            lines.append(
                "Unhealthy pods in \(namespace): \(unhealthy.isEmpty ? "none" : unhealthy.joined(separator: ", "))"
            )
        } else {
            lines.append("kubectl unavailable or namespace \(namespace) not found")
        }

        // Fact 2: compare with healthy peer namespace (squad-N → squad-M)
        if let peer = peerNamespace(namespace) {
            if let peerPods = kubectlGetPods(namespace: peer) {
                let peerUnhealthy = peerPods
                    .filter { $0.phase != "Running" && $0.phase != "Succeeded" }
                    .map { $0.name }
                lines.append(
                    "Peer namespace \(peer) unhealthy pods: "
                    + (peerUnhealthy.isEmpty ? "none (healthy)" : peerUnhealthy.joined(separator: ", "))
                )
            }
        } else if namespace.hasPrefix("squad-") {
            // namespace looks like squad but didn't match squad-N-suffix — log so it's observable
            fputs("[froggy-sre] warning: namespace '\(namespace)' starts with 'squad-' but doesn't match squad-<N>-<suffix> pattern — peer comparison skipped\n", stderr)
        }

        return lines.joined(separator: "\n")
    }

    private static let kubectlSearchPaths = [
        "/usr/local/bin/kubectl",
        "/opt/homebrew/bin/kubectl",
        "/opt/homebrew/opt/kubernetes-cli/bin/kubectl",
        "/usr/bin/kubectl",
    ]

    private static var kubectlPath: String? {
        kubectlSearchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func kubectlGetPods(namespace: String) -> [PodInfo]? {
        guard let kubectl = kubectlPath else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: kubectl)
        proc.arguments = ["get", "pods", "-n", namespace, "-o", "json"]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = json["items"] as? [[String: Any]]
        else { return nil }

        return items.compactMap { item -> PodInfo? in
            guard
                let meta   = item["metadata"] as? [String: Any],
                let name   = meta["name"] as? String,
                let status = item["status"]   as? [String: Any],
                let phase  = status["phase"]  as? String
            else { return nil }

            let containerStatuses = status["containerStatuses"] as? [[String: Any]] ?? []
            let restarts = containerStatuses.reduce(0) {
                $0 + (($1["restartCount"] as? Int) ?? 0)
            }
            return PodInfo(name: name, phase: phase, restarts: restarts)
        }
    }

    /// squad-1-kingdom2 → squad-2-kingdom2, squad-2-shared → squad-3-shared.
    /// Returns nil for non-squad namespaces (prod, preprod, kube-system, etc).
    static func peerNamespace(_ namespace: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(squad-)(\d+)(-.+)$"#) else { return nil }
        let range = NSRange(namespace.startIndex..., in: namespace)
        guard
            let match      = regex.firstMatch(in: namespace, range: range),
            let prefixRange = Range(match.range(at: 1), in: namespace),
            let numRange    = Range(match.range(at: 2), in: namespace),
            let suffixRange = Range(match.range(at: 3), in: namespace),
            let n           = Int(namespace[numRange])
        else { return nil }

        let peerN = n != 2 ? 2 : 3
        return "\(namespace[prefixRange])\(peerN)\(namespace[suffixRange])"
    }
}

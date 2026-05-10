import Foundation
import FroggyKit

/// Использует локальную модель Froggy для извлечения структурированных фактов из k8s-данных.
/// НЕ диагностирует — только извлекает. Диагностику делает Claude Code из результата.
public struct AnamnesisCollector: Sendable {
    private let llm = LLMRouter()
    public init() {}

    public func collect(incident: Incident, context: K8sContext) async -> String {
        let facts = await extractFacts(incident: incident, context: context)
        return format(incident: incident, context: context, facts: facts)
    }

    // MARK: - Extraction

    private func extractFacts(incident: Incident, context: K8sContext) async -> String {
        var rawParts: [String] = []
        if let logs = context.podLogs        { rawParts.append("=== Pod logs (tail) ===\n\(logs)") }
        if let evts = context.recentEvents   { rawParts.append("=== Warning events ===\n\(evts)") }
        if let desc = context.podDescription { rawParts.append("=== Pod describe ===\n\(desc)") }

        guard !rawParts.isEmpty else { return "(no k8s data — kubectl unavailable or pod/namespace not found)" }

        let raw = rawParts.joined(separator: "\n\n")
        let result = try? await llm.complete(
            system: """
            You are a Kubernetes observability data extractor.
            Extract ONLY facts from the raw data. Output as a short bullet list.
            Look specifically for:
            • exit codes (include signal name: SIGSEGV=139, SIGKILL=137, etc.)
            • error messages from the application logs
            • OOM indicators (OOMKilled, Killed, memory)
            • missing config / secrets / env vars
            • dependency failures (connection refused, timeout, DNS)
            • crash timing (how long pod ran before crash)
            • restart count and backoff interval
            Do NOT diagnose. Do NOT recommend. Facts only. Max 10 bullets.
            """,
            user: """
            Incident: \(incident.labelString)
            Annotations: \(incident.annotations.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

            \(raw)
            """
        )
        return result ?? "(extraction failed — Froggy daemon not running)"
    }

    // MARK: - Formatting

    private func format(incident: Incident, context: K8sContext, facts: String) -> String {
        var out: [String] = []

        // Header
        let labels = [
            incident.labels["alertname"].map { "**Alert**: \($0)" },
            incident.labels["namespace"].map { "**Namespace**: \($0)" },
            (incident.labels["pod"] ?? incident.labels["pod_name"]).map { "**Pod**: \($0)" },
            incident.labels["severity"].map { "**Severity**: \($0)" },
        ].compactMap { $0 }.joined(separator: " · ")
        out.append("## SRE Anamnesis")
        out.append(labels)
        if !incident.startsAt.isEmpty { out.append("**Started**: \(incident.startsAt)") }
        let annotations = incident.annotations.map { "**\($0.key)**: \($0.value)" }.joined(separator: "  \n")
        if !annotations.isEmpty { out.append(annotations) }

        // Extracted facts
        out.append("### Key Facts (extracted by local model)")
        out.append(facts)

        // Raw data
        if let evts = context.recentEvents {
            out.append("### Recent Warning Events")
            out.append("```\n\(evts)\n```")
        }
        if let logs = context.podLogs {
            out.append("### Pod Logs (tail)")
            out.append("```\n\(logs)\n```")
        }
        if let desc = context.podDescription {
            out.append("### Pod Description")
            out.append("```\n\(desc)\n```")
        }
        if context.isEmpty {
            out.append("*No k8s context fetched. Add `namespace` and `pod` labels to enable kubectl enrichment.*")
        }

        // Synthesis checklist — instructs Claude Code to validate fix vs root cause
        out.append("""
        ---
        ### Your diagnosis

        Using the facts above, provide:

        1. **Root cause** — specific and evidence-backed (cite key facts by bullet)
        2. **Fix** — concrete steps, `kubectl` commands or config changes, priority-ordered
        3. **Fix addresses root cause?** — answer YES or NO explicitly.\\
           If NO: explain the misalignment and propose an alternative fix that does.
        4. **Risk** — LOW / MEDIUM / HIGH + the key concern
        5. **Confidence** — 0–100% and what additional data would increase it
        """)

        return out.joined(separator: "\n\n")
    }
}

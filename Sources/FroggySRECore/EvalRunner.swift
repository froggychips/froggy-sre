import Foundation

/// Прогоняет датасет инцидентов через AgentPipeline и оценивает качество.
///
/// Три метрики:
/// - **Rubric**: keyword/phrase-чеки (expectedRootCause, mustMention, mustNotMention)
/// - **Hallucination score**: доля специфических токенов отчёта, реально
///   встречающихся в исходном контексте (labels + annotations + k8sContext).
///   Не ловит семантические галлюцинации, но детектирует выдуманные pod-имена,
///   exit-коды, namespace'ы.
/// - **Duration**: время прогона пайплайна
public struct EvalRunner: Sendable {
    public init() {}

    // MARK: - Single case

    public func run(evalCase: EvalCase, pipeline: AgentPipeline) async throws -> EvalResult {
        let clock = ContinuousClock()
        let start = clock.now
        let report = try await pipeline.process(evalCase.incident)
        let duration = (clock.now - start).seconds

        let rubricResult = evalCase.rubric.map { scoreRubric($0, report: report) }
        let hallScore    = Self.hallucinationScore(report: report, incident: evalCase.incident)

        return EvalResult(
            caseName:           evalCase.name ?? "unnamed",
            rubric:             rubricResult,
            hallucinationScore: hallScore,
            durationSeconds:    duration,
            report:             report
        )
    }

    // MARK: - Dataset batch

    /// Читает все .json из directory, прогоняет каждый, пишет summary в outputDir.
    @discardableResult
    public func runDataset(
        directory: URL,
        outputDir: URL,
        pipeline: AgentPipeline
    ) async throws -> [EvalResult] {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var results: [EvalResult] = []
        for file in files {
            let data     = try Data(contentsOf: file)
            var evalCase = try JSONDecoder().decode(EvalCase.self, from: data)
            if evalCase.name == nil {
                evalCase = EvalCase(
                    name:     file.deletingPathExtension().lastPathComponent,
                    incident: evalCase.incident,
                    rubric:   evalCase.rubric
                )
            }
            print("▶ \(evalCase.name ?? file.lastPathComponent)")
            let result = try await run(evalCase: evalCase, pipeline: pipeline)
            printResult(result)
            results.append(result)
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let md = summaryMarkdown(results)
        try md.write(to: outputDir.appendingPathComponent("eval_summary.md"),
                     atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results)
            .write(to: outputDir.appendingPathComponent("eval_results.json"))

        let passed = results.filter(\.passed).count
        print("\n═══ Eval complete: \(passed)/\(results.count) passed ═══\n")
        return results
    }

    // MARK: - Rubric scoring

    private func scoreRubric(_ rubric: EvalRubric, report: IncidentReport) -> RubricResult {
        let full = [
            report.analysis.summary,
            report.hypothesis.rootCause,
            report.critique?.notes ?? "",
            report.fix.action,
            report.risk.rationale
        ].joined(separator: "\n").lowercased()

        let rootCauseMatch = rubric.expectedRootCause.map {
            full.contains($0.lowercased())
        }
        let mustHits    = Dictionary(uniqueKeysWithValues:
            rubric.mustMention.map    { ($0, full.contains($0.lowercased())) })
        let mustNotHits = Dictionary(uniqueKeysWithValues:
            rubric.mustNotMention.map { ($0, full.contains($0.lowercased())) })

        return RubricResult(
            rootCauseMatch:       rootCauseMatch,
            mustMentionHits:      mustHits,
            mustNotMentionHits:   mustNotHits
        )
    }

    // MARK: - Hallucination proxy

    /// Строит словарь из всего что модель получила на вход, затем проверяет
    /// какая доля «специфических» токенов отчёта в нём встречается.
    /// Специфические токены — содержащие цифры, дефис (идентификаторы),
    /// или аббревиатуры (2+ uppercase-символа).
    public static func hallucinationScore(report: IncidentReport, incident: Incident) -> Double {
        var sourceText = incident.labels.values.joined(separator: " ")
        sourceText    += " " + incident.annotations.values.joined(separator: " ")
        if let ctx = incident.k8sContext {
            [ctx.podLogs, ctx.recentEvents, ctx.podDescription]
                .compactMap { $0 }.forEach { sourceText += " \($0)" }
        }
        guard sourceText.count > 20 else { return -1 }  // нет контекста — скоринг неприменим

        let sourceTokens = tokenSet(sourceText)

        let reportText = [
            report.analysis.summary,
            report.hypothesis.rootCause,
            report.critique?.notes ?? "",
            report.fix.action,
            report.risk.rationale
        ].joined(separator: " ")

        let claims = tokenSet(reportText).filter(isSpecific)
        guard !claims.isEmpty else { return 1.0 }

        let grounded = claims.filter { sourceTokens.contains($0) }
        return Double(grounded.count) / Double(claims.count)
    }

    private static func tokenSet(_ text: String) -> Set<String> {
        let punct = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "-_"))
        return Set(
            text.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: punct) }
                .filter { !$0.isEmpty }
        )
    }

    private static func isSpecific(_ token: String) -> Bool {
        guard token.count >= 3 else { return false }
        if token.contains(where: \.isNumber)  { return true }
        if token.contains("-") && token.count >= 5 { return true }
        let uppers = token.filter(\.isUppercase)
        if uppers.count >= 2 && uppers.count < token.count { return true }  // аббревиатура/CamelCase
        return false
    }

    // MARK: - Output

    private func printResult(_ r: EvalResult) {
        let status = r.passed ? "✓" : "✗"
        let hall   = r.hallucinationScore >= 0
            ? String(format: "hall=%.2f", r.hallucinationScore) : "hall=n/a"
        let dur    = String(format: "%.1fs", r.durationSeconds)
        print("  \(status) \(r.caseName)  \(hall)  \(dur)")
        if let rb = r.rubric {
            if let rc = rb.rootCauseMatch { print("    rootCause: \(rc ? "✓" : "✗")") }
            rb.mustMentionHits.sorted(by: { $0.key < $1.key }).forEach { k, v in
                print("    mustMention '\(k)': \(v ? "✓" : "✗")")
            }
            rb.mustNotMentionHits.sorted(by: { $0.key < $1.key }).forEach { k, v in
                print("    mustNotMention '\(k)': \(v ? "✗ FOUND" : "✓ absent")")
            }
        }
    }

    private func summaryMarkdown(_ results: [EvalResult]) -> String {
        var s = "# Eval Summary\n\n"
        s += "_\(results.count) cases — \(results.filter(\.passed).count) passed_\n\n"

        s += "| Case | Pass | Root cause | Must mention | Must not | Hall score | Duration |\n"
        s += "|---|---|---|---|---|---|---|\n"
        for r in results {
            let pass = r.passed ? "✓" : "✗"
            let rc   = r.rubric?.rootCauseMatch.map { $0 ? "✓" : "✗" } ?? "–"
            let mm: String
            if let hits = r.rubric?.mustMentionHits, !hits.isEmpty {
                let ok = hits.values.filter { $0 }.count
                mm = "\(ok)/\(hits.count)"
            } else { mm = "–" }
            let mn: String
            if let hits = r.rubric?.mustNotMentionHits, !hits.isEmpty {
                let bad = hits.values.filter { $0 }.count
                mn = bad == 0 ? "✓" : "✗\(bad)"
            } else { mn = "–" }
            let hall = r.hallucinationScore >= 0
                ? String(format: "%.2f", r.hallucinationScore) : "n/a"
            let dur  = String(format: "%.1fs", r.durationSeconds)
            s += "| \(r.caseName) | \(pass) | \(rc) | \(mm) | \(mn) | \(hall) | \(dur) |\n"
        }

        s += "\n## Details\n\n"
        for r in results {
            s += "### \(r.caseName)\n\n"
            s += "**Root cause:** \(r.report.hypothesis.rootCause)\n\n"
            s += "**Fix:** \(r.report.fix.action)\n\n"
            s += "**Risk:** \(r.report.risk.score) — \(r.report.risk.rationale)\n\n"
            if let rb = r.rubric, !rb.passed {
                s += "**Failures:**\n"
                if rb.rootCauseMatch == false { s += "- root cause mismatch\n" }
                rb.mustMentionHits.filter { !$0.value }.forEach { s += "- missing: '\($0.key)'\n" }
                rb.mustNotMentionHits.filter { $0.value }.forEach { s += "- false positive: '\($0.key)'\n" }
                s += "\n"
            }
        }
        return s
    }
}

private extension Duration {
    var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1_000_000_000_000_000_000.0
    }
}

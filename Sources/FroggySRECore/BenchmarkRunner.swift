import Foundation

public struct StageMetric: Codable, Sendable {
    public let stage: String
    public let durationSeconds: Double
    public let memoryPressurePct: Int
    public let outputPreview: String
}

public struct BenchmarkResult: Codable, Sendable {
    public let modelName: String
    public let runDate: String
    public let totalDurationSeconds: Double
    public let stages: [StageMetric]
    public let report: IncidentReport
}

/// Collects StageMetric values safely from @Sendable closures.
private actor MetricsCollector {
    private var items: [StageMetric] = []
    func append(_ m: StageMetric) { items.append(m) }
    func all() -> [StageMetric] { items }
}

public struct BenchmarkRunner: Sendable {
    public init() {}

    public func run(
        incidentFile: URL,
        outputDir: URL,
        modelName: String
    ) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incident = try decoder.decode(Incident.self, from: Data(contentsOf: incidentFile))

        let runDir   = outputDir.appendingPathComponent(modelName)
        let storeDir = runDir.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let collector  = MetricsCollector()
        let clock      = ContinuousClock()
        let totalStart = clock.now

        let store    = IncidentStore(directory: storeDir)
        let pipeline = AgentPipeline(store: store) { stage, duration, output in
            let metric = StageMetric(
                stage: stage,
                durationSeconds: duration.seconds,
                memoryPressurePct: BenchmarkRunner.memoryPressurePct(),
                outputPreview: output
            )
            await collector.append(metric)
            let pct = metric.memoryPressurePct
            let bar = String(repeating: "█", count: max(0, min(pct, 100)) / 10)
                    + String(repeating: "░", count: 10 - max(0, min(pct, 100)) / 10)
            print("  [\(stage)] \(String(format: "%.1f", metric.durationSeconds))s  mem [\(bar)] \(pct)%")
        }

        print("\n═══ Bench: \(modelName) ═══")
        let report  = try await pipeline.process(incident)
        let total   = (clock.now - totalStart).seconds
        let metrics = await collector.all()

        let result = BenchmarkResult(
            modelName: modelName,
            runDate: ISO8601DateFormatter().string(from: Date()),
            totalDurationSeconds: total,
            stages: metrics,
            report: report
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: runDir.appendingPathComponent("metrics.json"))

        let md = markdown(result)
        try md.write(to: runDir.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)

        print("  ─────────────────────────")
        print("  Total: \(String(format: "%.1f", total))s  →  \(runDir.path)\n")
    }

    // MARK: - Memory

    static func memoryPressurePct() -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        guard (try? proc.run()) != nil else { return -1 }
        proc.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var vals: [String: Int64] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = Int64(parts[1].trimmingCharacters(in: .init(charactersIn: " ."))) ?? 0
            vals[key] = val
        }

        let free       = vals["Pages free"]                  ?? 0
        let inactive   = vals["Pages inactive"]              ?? 0
        let active     = vals["Pages active"]                ?? 0
        let wired      = vals["Pages wired down"]            ?? 0
        let compressed = vals["Pages stored in compressor"]  ?? 0
        let total = free + inactive + active + wired + compressed
        guard total > 0 else { return -1 }
        return Int((wired + active + compressed) * 100 / total)
    }

    // MARK: - Markdown output

    private func markdown(_ r: BenchmarkResult) -> String {
        var s = "# Benchmark: \(r.modelName)\n"
        s += "_\(r.runDate) | total: \(String(format: "%.1f", r.totalDurationSeconds))s_\n\n"

        s += "## Stage timings\n\n"
        s += "| Stage | Time | Memory |\n|---|---|---|\n"
        for m in r.stages {
            s += "| \(m.stage) | \(String(format: "%.1f", m.durationSeconds))s | \(m.memoryPressurePct)% |\n"
        }
        s += "\n"

        s += "## Analyzer\n\n\(r.report.analysis.summary)\n\n"
        s += "## Hypothesis\n\n\(r.report.hypothesis.rootCause)\n\n"
        if let c = r.report.critique {
            s += "## Critic\n\n\(c.notes)\n\n"
        }
        s += "## Fix\n\n\(r.report.fix.action)\n\n"
        s += "## Risk\n\nScore: \(r.report.risk.score)\n\n\(r.report.risk.rationale)\n\n"

        s += "## Rubric checklist\n\n"
        let full = [
            r.report.analysis.summary,
            r.report.hypothesis.rootCause,
            r.report.critique?.notes ?? "",
            r.report.fix.action,
            r.report.risk.rationale
        ].joined(separator: "\n")

        func check(_ text: String, _ needle: String) -> String {
            text.lowercased().contains(needle.lowercased()) ? "x" : " "
        }
        let diMentioned = full.lowercased().contains("dependency injection")
            || full.lowercased().contains(" di ")
            || full.lowercased().contains("service registration")
        let criticHasContent = (r.report.critique?.notes.count ?? 0) > 20
        let hasRollback = full.lowercased().contains("rollback")
            || full.lowercased().contains("revert")

        s += "- [\(check(full, "CityEffectListProvider"))] Named `CityEffectListProvider`\n"
        s += "- [\(check(full, "Program.cs"))] Named `Program.cs:80`\n"
        s += "- [\(diMentioned ? "x" : " ")] Root cause: DI registration\n"
        s += "- [\(check(full, "SkillBase"))] Fix mentions `IStaticEntityComponentIndex<SkillBase>`\n"
        s += "- [\(criticHasContent ? "x" : " ")] Critic found weakness\n"
        s += "- [\(hasRollback ? "x" : " ")] Risk includes rollback\n"
        return s
    }
}

private extension Duration {
    var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1_000_000_000_000_000_000.0
    }
}

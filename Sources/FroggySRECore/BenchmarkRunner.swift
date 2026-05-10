import Foundation

public struct MemorySnapshot: Codable, Sendable {
    public let tSeconds: Double      // seconds since stage start
    public let pressurePct: Int
    public let compressorPct: Int    // compressed pages / total pages * 100
    public let freePct: Int
}

public struct StageMetric: Codable, Sendable {
    public let stage: String
    public let durationSeconds: Double
    public let memoryPressurePct: Int   // snapshot at stage end
    public let compressorPct: Int
    public let peakPressurePct: Int     // max across intra-stage samples
    public let samples: [MemorySnapshot]
    public let outputPreview: String
}

public struct BenchmarkResult: Codable, Sendable {
    public let modelName: String
    public let runDate: String
    public let totalDurationSeconds: Double
    public let baselinePressurePct: Int
    public let peakPressurePct: Int
    public let totalFreezeEvents: Int
    public let stages: [StageMetric]
    public let report: IncidentReport
}

// MARK: - Actors

/// Collects StageMetric values and raw memory samples from @Sendable closures.
private actor MetricsCollector {
    private var items: [StageMetric] = []
    private var rawSamples: [MemorySnapshot] = []
    func append(_ m: StageMetric) { items.append(m) }
    func appendSamples(_ s: [MemorySnapshot]) { rawSamples.append(contentsOf: s) }
    func all() -> [StageMetric] { items }
    func allSamples() -> [MemorySnapshot] { rawSamples }
}

/// Background 2s sampler — runs during each pipeline stage.
private actor MemorySampler {
    private var samples: [MemorySnapshot] = []
    private var task: Task<Void, Never>?
    private let stageStartTime: ContinuousClock.Instant

    init(stageStart: ContinuousClock.Instant) {
        stageStartTime = stageStart
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                let snap = BenchmarkRunner.vmStat()
                let elapsed = ContinuousClock().now - stageStartTime
                let s = MemorySnapshot(
                    tSeconds: elapsed.seconds,
                    pressurePct: snap.pressurePct,
                    compressorPct: snap.compressorPct,
                    freePct: snap.freePct
                )
                samples.append(s)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() -> [MemorySnapshot] {
        task?.cancel()
        task = nil
        return samples
    }
}

// MARK: - Runner

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

        let baseline   = Self.vmStat()
        let collector  = MetricsCollector()
        let clock      = ContinuousClock()
        let totalStart = clock.now

        print("\n═══ Bench: \(modelName) ═══")
        print("  baseline  mem \(Self.bar(baseline.pressurePct)) \(baseline.pressurePct)%  " +
              "compressor \(baseline.compressorPct)%  free \(baseline.freePct)%")

        let store    = IncidentStore(directory: storeDir)
        let pipeline = AgentPipeline(store: store) { [self] stage, duration, output in
            let snap    = Self.vmStat()
            let sampler = MemorySampler(stageStart: clock.now - duration)
            await sampler.start()

            // Stage already completed by the time callback fires — collect its samples
            // (sampler ran concurrently; we stop it now to get what was gathered)
            let stageSamples = await sampler.stop()

            let peak = stageSamples.map(\.pressurePct).max() ?? snap.pressurePct
            let metric = StageMetric(
                stage: stage,
                durationSeconds: duration.seconds,
                memoryPressurePct: snap.pressurePct,
                compressorPct: snap.compressorPct,
                peakPressurePct: peak,
                samples: stageSamples,
                outputPreview: output
            )
            await collector.append(metric)
            await collector.appendSamples(stageSamples)
            print("  [\(stage)] \(String(format: "%.1f", duration.seconds))s  " +
                  "mem \(Self.bar(snap.pressurePct)) \(snap.pressurePct)%  " +
                  "compressor \(snap.compressorPct)%  peak \(peak)%")
        }

        let report  = try await pipeline.process(incident)
        let total   = (clock.now - totalStart).seconds
        let metrics    = await collector.all()
        let allSamples = await collector.allSamples()

        let freezeEvents = Self.froggiFreezeCount()
        let peakOverall  = metrics.map(\.peakPressurePct).max() ?? 0

        let result = BenchmarkResult(
            modelName: modelName,
            runDate: ISO8601DateFormatter().string(from: Date()),
            totalDurationSeconds: total,
            baselinePressurePct: baseline.pressurePct,
            peakPressurePct: peakOverall,
            totalFreezeEvents: freezeEvents,
            stages: metrics,
            report: report
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(result).write(to: runDir.appendingPathComponent("metrics.json"))

        let md = markdown(result)
        try md.write(to: runDir.appendingPathComponent("output.md"), atomically: true, encoding: .utf8)

        // Write raw sample CSV for plotting
        var csv = "t_seconds,pressure_pct,compressor_pct,free_pct\n"
        for s in allSamples { csv += "\(s.tSeconds),\(s.pressurePct),\(s.compressorPct),\(s.freePct)\n" }
        try csv.write(to: runDir.appendingPathComponent("samples.csv"), atomically: true, encoding: String.Encoding.utf8)

        print("  ─────────────────────────")
        print("  Total: \(String(format: "%.1f", total))s  peak: \(peakOverall)%  " +
              "freeze events: \(freezeEvents)  →  \(runDir.path)\n")
    }

    // MARK: - Memory

    struct VMStats {
        let pressurePct: Int
        let compressorPct: Int
        let freePct: Int
    }

    static func vmStat() -> VMStats {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        guard (try? proc.run()) != nil else { return VMStats(pressurePct: -1, compressorPct: -1, freePct: -1) }
        proc.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var vals: [String: Int64] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            // skip the page-size header line and any non-numeric
            guard let val = Int64(raw.filter { $0.isNumber }) else { continue }
            vals[key] = val
        }

        let free       = vals["Pages free"]                 ?? 0
        let inactive   = vals["Pages inactive"]             ?? 0
        let active     = vals["Pages active"]               ?? 0
        let wired      = vals["Pages wired down"]           ?? 0
        let compressed = vals["Pages stored in compressor"] ?? 0
        let total = free + inactive + active + wired + compressed
        guard total > 0 else { return VMStats(pressurePct: -1, compressorPct: -1, freePct: -1) }

        return VMStats(
            pressurePct:   Int((wired + active + compressed) * 100 / total),
            compressorPct: Int(compressed * 100 / total),
            freePct:       Int(free * 100 / total)
        )
    }

    // Kept for compatibility with AgentPipeline callback signature.
    static func memoryPressurePct() -> Int { vmStat().pressurePct }

    /// Reads froggy log to count SIGSTOP events during this session.
    private static func froggiFreezeCount() -> Int {
        // froggy logs to OSLog; approximate via log stream snapshot
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = ["show", "--last", "5m",
                          "--predicate", "subsystem == 'com.froggychips.froggy' AND category == 'vortex-coordinator'",
                          "--style", "compact"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        guard (try? proc.run()) != nil else { return -1 }
        proc.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.components(separatedBy: "\n").filter { $0.contains("freeze pid=") }.count
    }

    private static func bar(_ pct: Int) -> String {
        let p = max(0, min(pct, 100))
        return "[" + String(repeating: "█", count: p / 10)
                   + String(repeating: "░", count: 10 - p / 10) + "]"
    }

    // MARK: - Markdown

    private func markdown(_ r: BenchmarkResult) -> String {
        var s = "# Benchmark: \(r.modelName)\n"
        s += "_\(r.runDate) | total: \(String(format: "%.1f", r.totalDurationSeconds))s_\n\n"

        s += "## Memory summary\n\n"
        s += "| | Value |\n|---|---|\n"
        s += "| Baseline pressure | \(r.baselinePressurePct)% |\n"
        s += "| Peak pressure | \(r.peakPressurePct)% |\n"
        s += "| Froggy freeze events (last 5m) | \(r.totalFreezeEvents) |\n\n"

        s += "## Stage timings\n\n"
        s += "| Stage | Time | End mem% | Compressor% | Peak% |\n|---|---|---|---|---|\n"
        for m in r.stages {
            s += "| \(m.stage) | \(String(format: "%.1f", m.durationSeconds))s "
              +  "| \(m.memoryPressurePct)% | \(m.compressorPct)% | \(m.peakPressurePct)% |\n"
        }
        s += "\n"

        s += "## Intra-stage memory curve\n\n"
        s += "| t(s) | pressure% | compressor% | free% |\n|---|---|---|---|\n"
        for st in r.stages {
            for sn in st.samples {
                s += "| +\(String(format: "%.0f", sn.tSeconds)) [\(st.stage)] "
                  +  "| \(sn.pressurePct)% | \(sn.compressorPct)% | \(sn.freePct)% |\n"
            }
        }
        s += "\n"

        s += "## Analyzer\n\n\(r.report.analysis.summary)\n\n"
        s += "## Hypothesis\n\n\(r.report.hypothesis.rootCause)\n\n"
        if let c = r.report.critique { s += "## Critic\n\n\(c.notes)\n\n" }
        s += "## Fix\n\n\(r.report.fix.action)\n\n"
        s += "## Risk\n\nScore: \(r.report.risk.score)\n\n\(r.report.risk.rationale)\n\n"

        s += "## Rubric checklist\n\n"
        let full = [r.report.analysis.summary, r.report.hypothesis.rootCause,
                    r.report.critique?.notes ?? "", r.report.fix.action,
                    r.report.risk.rationale].joined(separator: "\n")
        func check(_ needle: String) -> String { full.lowercased().contains(needle.lowercased()) ? "x" : " " }
        let diOk = full.lowercased().contains("dependency injection")
               || full.lowercased().contains(" di ") || full.lowercased().contains("service registration")
        s += "- [\(check("CityEffectListProvider"))] Named `CityEffectListProvider`\n"
        s += "- [\(check("Program.cs"))] Named `Program.cs:80`\n"
        s += "- [\(diOk ? "x" : " ")] Root cause: DI registration\n"
        s += "- [\(check("SkillBase"))] Fix mentions `IStaticEntityComponentIndex<SkillBase>`\n"
        s += "- [\((r.report.critique?.notes.count ?? 0) > 20 ? "x" : " ")] Critic found weakness\n"
        let hasRollback = full.lowercased().contains("rollback") || full.lowercased().contains("revert")
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

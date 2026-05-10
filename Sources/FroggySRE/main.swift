import Foundation
import FroggySRECore

let argv = CommandLine.arguments.dropFirst()

func flag(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name) else { return nil }
    let next = argv.index(after: i)
    guard next < argv.endIndex else { return nil }
    return argv[next]
}

if argv.contains("bench") {
    guard
        let incidentPath = flag("--incident"),
        let outputPath   = flag("--output"),
        let modelName    = flag("--model")
    else {
        fputs("usage: froggy-sre bench --incident <file.json> --output <runs-dir> --model <name>\n", stderr)
        exit(1)
    }
    let runner = BenchmarkRunner()
    do {
        try await runner.run(
            incidentFile: URL(fileURLWithPath: incidentPath),
            outputDir:    URL(fileURLWithPath: outputPath),
            modelName:    modelName
        )
    } catch {
        fputs("bench failed: \(error)\n", stderr)
        exit(1)
    }

} else if argv.contains("snapshot") {
    guard let ns = flag("--namespace") else {
        fputs("usage: froggy-sre snapshot --namespace <ns> [--pod <pod>] [--alertname <name>] --output <file.json>\n", stderr)
        exit(1)
    }
    let pod       = flag("--pod") ?? ""
    let alertname = flag("--alertname") ?? "CrashLoopBackOff"
    let output    = flag("--output")

    var labels: [String: String] = ["namespace": ns, "alertname": alertname]
    if !pod.isEmpty { labels["pod"] = pod }

    let stub     = Incident(labels: labels, annotations: [:], startsAt: ISO8601DateFormatter().string(from: Date()))
    let ctx      = await K8sContextFetcher().fetch(for: stub)
    let incident = Incident(labels: labels, annotations: [:], startsAt: stub.startsAt, k8sContext: ctx)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(incident)

    if let outPath = output {
        try data.write(to: URL(fileURLWithPath: outPath))
        print("snapshot saved → \(outPath)")
    } else {
        print(String(data: data, encoding: .utf8)!)
    }

} else if argv.contains("--daemon") {
    let daemon = SREDaemon()
    await daemon.run()

} else {
    let server = MCPServer()
    await server.run()
}

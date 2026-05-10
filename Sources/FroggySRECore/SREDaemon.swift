import Foundation

/// Listens on a Unix socket for incident events and drives the agent pipeline.
public actor SREDaemon {
    private let socketPath: String
    private let pipeline: AgentPipeline

    public init(socketPath: String = "/tmp/froggy-sre.sock") {
        self.socketPath = socketPath
        self.pipeline = AgentPipeline()
    }

    public func run() async {
        print("[froggy-sre] starting on \(socketPath)")
        // TODO: Unix socket server (mirrors froggy-mcp IPC pattern)
        // TODO: Accept incident events from Froggy daemon or direct webhook
        // TODO: Route to AgentPipeline, return structured IncidentReport
    }
}

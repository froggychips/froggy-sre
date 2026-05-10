import Foundation

/// Standalone Unix socket daemon mode.
/// Accepts JSON incident payloads, runs the agent pipeline, returns JSON IncidentReport.
/// Usage: froggy-sre --daemon [--socket /path/to/sre.sock]
public struct SREDaemon: Sendable {
    private let socketPath: String
    private let pipeline: AgentPipeline

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath
            ?? ProcessInfo.processInfo.environment["FROGGY_SRE_SOCKET"]
            ?? "/tmp/froggy-sre.sock"
        self.pipeline = AgentPipeline()
    }

    public func run() async {
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("[froggy-sre] socket creation failed"); return }
        defer {
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in pathBytes.enumerated() { buf.storeBytes(of: b, toByteOffset: i, as: UInt8.self) }
            buf.storeBytes(of: 0, toByteOffset: pathBytes.count, as: UInt8.self)
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
        guard bound else { print("[froggy-sre] bind failed on \(socketPath)"); return }

        Darwin.listen(fd, 5)
        print("[froggy-sre] daemon: listening on \(socketPath)")

        while true {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { continue }
            Task.detached { [self] in
                defer { Darwin.close(client) }
                guard let incident = Self.readIncident(fd: client) else { return }
                guard let report   = try? await pipeline.process(incident) else { return }
                Self.writeReport(report, fd: client)
            }
        }
    }

    private static func readIncident(fd: Int32) -> Incident? {
        var buffer = Data()
        let chunk  = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 1)
        defer { chunk.deallocate() }
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        withUnsafePointer(to: &tv) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        while true {
            let n = Darwin.recv(fd, chunk, 4096, 0)
            if n <= 0 { break }
            buffer.append(Data(bytes: chunk, count: n))
            if let nl = buffer.firstIndex(of: 0x0A) {
                return try? JSONDecoder().decode(Incident.self, from: buffer[buffer.startIndex..<nl])
            }
        }
        return nil
    }

    private static func writeReport(_ report: IncidentReport, fd: Int32) {
        guard var data = try? JSONEncoder().encode(report) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
    }
}

import Foundation

public struct LLMCallInfo: Sendable, Codable, Equatable {
    public let backend: String
    public let durationMs: Int
    public let fallbackUsed: Bool
    public let error: String?

    public init(backend: String, durationMs: Int, fallbackUsed: Bool, error: String? = nil) {
        self.backend = backend
        self.durationMs = durationMs
        self.fallbackUsed = fallbackUsed
        self.error = error
    }
}

public actor LLMTraceRecorder {
    public private(set) var calls: [LLMCallInfo] = []
    public init() {}
    public func record(_ call: LLMCallInfo) { calls.append(call) }
    public func snapshot() -> [LLMCallInfo] { calls }
}

public struct StageTrace: Sendable, Codable, Equatable {
    public let stage: String
    public let durationMs: Int
    public let llmCalls: [LLMCallInfo]

    public init(stage: String, durationMs: Int, llmCalls: [LLMCallInfo]) {
        self.stage = stage
        self.durationMs = durationMs
        self.llmCalls = llmCalls
    }
}

func durationMs(_ d: Duration) -> Int {
    let (s, a) = d.components
    return Int(Double(s) * 1000 + Double(a) / 1e15)
}

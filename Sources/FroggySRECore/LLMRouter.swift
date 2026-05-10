import Foundation
import FroggyKit

/// Enables LLM dependency injection — production code uses LLMRouter, tests use MockLLM.
public protocol LLMCompleting: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// Routes LLM calls based on FROGGY_SRE_BACKEND env var.
///
/// froggy (default): Froggy daemon → Anthropic fallback
/// lmstudio:         LM Studio local API → no fallback
@usableFromInline
struct LLMRouter: LLMCompleting, Sendable {
    private let froggy    = FroggyClient()
    private let anthropic = AnthropicClient()
    private let lmstudio  = LMStudioClient()
    private let backend   = ProcessInfo.processInfo.environment["FROGGY_SRE_BACKEND"] ?? "froggy"

    @usableFromInline init() {}

    @usableFromInline
    func complete(system: String, user: String) async throws -> String {
        switch backend {
        case "lmstudio":
            return try await lmstudio.complete(system: system, user: user)
        default:
            if let result = try? await froggy.generate(prompt: "\(system)\n\n\(user)") {
                return result
            }
            guard !anthropic.apiKey.isEmpty else {
                throw LLMRouterError.noBackendAvailable
            }
            return try await anthropic.complete(system: system, user: user)
        }
    }
}

enum LLMRouterError: Error, LocalizedError {
    case noBackendAvailable
    var errorDescription: String? {
        "нет доступного LLM-бэкенда: запусти Froggy daemon или задай ANTHROPIC_API_KEY"
    }
}

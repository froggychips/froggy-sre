import Foundation
import os
import FroggyKit

/// Enables LLM dependency injection — production code uses LLMRouter, tests use MockLLM.
public protocol LLMCompleting: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// Routes LLM calls based on FROGGY_SRE_BACKEND env var.
///
/// froggy (default): Froggy daemon → Anthropic fallback
/// lmstudio:         LM Studio local API → no fallback
///
/// Per-call metadata (backend used, duration, fallback, error) is published into
/// the task-local `recorder` if AgentPipeline (or a test) bound one with
/// `LLMRouter.$recorder.withValue(...)`. Silent for unbound contexts.
@usableFromInline
struct LLMRouter: LLMCompleting, Sendable {
    @TaskLocal static var recorder: LLMTraceRecorder?

    static let logger = Logger(subsystem: "froggychips.froggy-sre", category: "llm")

    private let froggy    = FroggyClient()
    private let anthropic = AnthropicClient()
    private let lmstudio  = LMStudioClient()
    private let backend   = ProcessInfo.processInfo.environment["FROGGY_SRE_BACKEND"] ?? "froggy"

    @usableFromInline init() {}

    @usableFromInline
    func complete(system: String, user: String) async throws -> String {
        let clock = ContinuousClock()
        switch backend {
        case "lmstudio":
            return try await callLMStudio(system: system, user: user, clock: clock)
        default:
            return try await callFroggyThenAnthropic(system: system, user: user, clock: clock)
        }
    }

    // MARK: - LM Studio path (no fallback)

    private func callLMStudio(system: String, user: String, clock: ContinuousClock) async throws -> String {
        let start = clock.now
        do {
            let text = try await lmstudio.complete(system: system, user: user)
            let dur = durationMs(clock.now - start)
            Self.logger.debug("backend=lmstudio duration=\(dur)ms ok")
            await Self.recorder?.record(.init(backend: "lmstudio", durationMs: dur, fallbackUsed: false))
            return text
        } catch {
            let dur = durationMs(clock.now - start)
            let msg = Self.classify(error)
            Self.logger.error("backend=lmstudio duration=\(dur)ms error=\(msg, privacy: .public)")
            await Self.recorder?.record(.init(backend: "lmstudio", durationMs: dur, fallbackUsed: false, error: msg))
            throw error
        }
    }

    // MARK: - Froggy → Anthropic path

    private func callFroggyThenAnthropic(system: String, user: String, clock: ContinuousClock) async throws -> String {
        let froggyStart = clock.now
        do {
            let text = try await froggy.generate(prompt: "\(system)\n\n\(user)")
            let dur = durationMs(clock.now - froggyStart)
            Self.logger.debug("backend=froggy duration=\(dur)ms ok")
            await Self.recorder?.record(.init(backend: "froggy", durationMs: dur, fallbackUsed: false))
            return text
        } catch FroggyClientError.daemonNotRunning {
            // Expected when no daemon is running: silent debug, not error.
            let dur = durationMs(clock.now - froggyStart)
            Self.logger.debug("backend=froggy duration=\(dur)ms fallback=anthropic reason=daemonNotRunning")
            await Self.recorder?.record(.init(backend: "froggy", durationMs: dur, fallbackUsed: true, error: "daemonNotRunning"))
        } catch {
            // Unexpected froggy failure (timeout, daemon-side error, etc): logged as error but we still try anthropic.
            let dur = durationMs(clock.now - froggyStart)
            let msg = Self.classify(error)
            Self.logger.error("backend=froggy duration=\(dur)ms fallback=anthropic error=\(msg, privacy: .public)")
            await Self.recorder?.record(.init(backend: "froggy", durationMs: dur, fallbackUsed: true, error: msg))
        }

        guard !anthropic.apiKey.isEmpty else {
            throw LLMRouterError.noBackendAvailable
        }

        let antStart = clock.now
        do {
            let text = try await anthropic.complete(system: system, user: user)
            let dur = durationMs(clock.now - antStart)
            Self.logger.debug("backend=anthropic duration=\(dur)ms ok")
            await Self.recorder?.record(.init(backend: "anthropic", durationMs: dur, fallbackUsed: false))
            return text
        } catch {
            let dur = durationMs(clock.now - antStart)
            let msg = Self.classify(error)
            Self.logger.error("backend=anthropic duration=\(dur)ms error=\(msg, privacy: .public)")
            await Self.recorder?.record(.init(backend: "anthropic", durationMs: dur, fallbackUsed: false, error: msg))
            throw error
        }
    }

    // MARK: - Error classification

    private static func classify(_ error: Error) -> String {
        if let fce = error as? FroggyClientError {
            switch fce {
            case .socketCreation:   return "socketCreation"
            case .connection:       return "connection"
            case .daemonNotRunning: return "daemonNotRunning"
            case .daemon:           return "daemon"
            case .timeout:          return "timeout"
            }
        }
        return String(describing: type(of: error))
    }
}

enum LLMRouterError: Error, LocalizedError {
    case noBackendAvailable
    var errorDescription: String? {
        "нет доступного LLM-бэкенда: запусти Froggy daemon или задай ANTHROPIC_API_KEY"
    }
}

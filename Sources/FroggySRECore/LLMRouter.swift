/// Routes LLM calls to the local Froggy daemon when available;
/// falls back to Anthropic API otherwise.
///
/// Priority: Froggy (private, free) → Anthropic (cloud, requires API key)
struct LLMRouter: Sendable {
    private let froggy    = FroggyClient()
    private let anthropic = AnthropicClient()

    func complete(system: String, user: String) async throws -> String {
        // Froggy has no system/user split — combine into a single prompt
        if let result = try? await froggy.generate(prompt: "\(system)\n\n\(user)") {
            return result
        }
        // Daemon not running or model not loaded — fall back to Anthropic
        return try await anthropic.complete(system: system, user: user)
    }
}

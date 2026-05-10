import Foundation

/// Minimal Anthropic Messages API client — no external dependencies.
struct AnthropicClient: Sendable {
    let apiKey: String
    let model: String
    let session: URLSession
    let retryBaseDelay: Double

    init(apiKey: String? = nil, session: URLSession = .shared, retryBaseDelay: Double = 1.0) {
        let env    = ProcessInfo.processInfo.environment
        self.apiKey         = apiKey ?? env["ANTHROPIC_API_KEY"] ?? ""
        self.model          = env["FROGGY_SRE_MODEL"] ?? "claude-haiku-4-5-20251001"
        self.session        = session
        self.retryBaseDelay = retryBaseDelay
    }

    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicError.missingAPIKey }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey,             forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model":      model,
            "max_tokens": 1024,
            "system":     system,
            "messages":   [["role": "user", "content": user]]
        ])

        let retryable: Set<Int> = [429, 500, 529]
        let maxAttempts = 4  // 1 initial + 3 retries

        for attempt in 0..<maxAttempts {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AnthropicError.invalidResponse }

            if http.statusCode == 200 {
                guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let content = json["content"] as? [[String: Any]],
                      let text    = content.first?["text"] as? String
                else { throw AnthropicError.invalidResponse }
                return text
            }

            guard retryable.contains(http.statusCode), attempt < maxAttempts - 1 else {
                throw AnthropicError.httpError(http.statusCode)
            }

            // Respect Retry-After header; fall back to exponential backoff (1s, 2s, 4s).
            let delay: Double
            if let header = http.value(forHTTPHeaderField: "retry-after"), let s = Double(header) {
                delay = s
            } else {
                delay = retryBaseDelay * pow(2.0, Double(attempt))
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        throw AnthropicError.httpError(0)  // unreachable
    }
}

enum AnthropicError: Error, LocalizedError {
    case missingAPIKey
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:    return "ANTHROPIC_API_KEY не задан"
        case .httpError(let c): return "Anthropic API вернул HTTP \(c)"
        case .invalidResponse:  return "Anthropic API: неожиданный формат ответа"
        }
    }
}

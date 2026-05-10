import Foundation

/// Minimal Anthropic Messages API client — no external dependencies.
struct AnthropicClient: Sendable {
    let apiKey: String
    let model: String

    init() {
        let env = ProcessInfo.processInfo.environment
        apiKey = env["ANTHROPIC_API_KEY"] ?? ""
        model  = env["FROGGY_SRE_MODEL"] ?? "claude-haiku-4-5-20251001"
    }

    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AnthropicError.missingAPIKey }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw AnthropicError.httpError(code)
        }
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text    = content.first?["text"] as? String
        else { throw AnthropicError.invalidResponse }
        return text
    }
}

enum AnthropicError: Error {
    case missingAPIKey
    case httpError(Int)
    case invalidResponse
}

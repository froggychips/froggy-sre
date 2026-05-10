import Foundation

/// OpenAI-compatible client for LM Studio local server.
/// Base URL: LM_STUDIO_URL env (default http://localhost:1234)
/// Model:    LM_STUDIO_MODEL env (default: first model from /v1/models)
struct LMStudioClient: Sendable {
    private let baseURL: String
    private let model: String

    init() {
        let env = ProcessInfo.processInfo.environment
        baseURL = env["LM_STUDIO_URL"] ?? "http://localhost:1234"
        model   = env["LM_STUDIO_MODEL"] ?? Self.detectModel(baseURL: env["LM_STUDIO_URL"] ?? "http://localhost:1234")
    }

    func complete(system: String, user: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LMStudioError.badURL
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system",  "content": system],
                ["role": "user",    "content": user]
            ],
            "max_tokens": 600,
            "temperature": 0.2
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LMStudioError.httpError((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard
            let json    = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first   = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LMStudioError.invalidResponse }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func detectModel(baseURL: String) -> String {
        guard
            let url  = URL(string: "\(baseURL)/v1/models"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json["data"] as? [[String: Any]],
            let id   = list.first?["id"] as? String
        else { return "llama-3.2-1b-instruct" }
        return id
    }
}

enum LMStudioError: Error, LocalizedError {
    case badURL
    case httpError(Int)
    case invalidResponse
    case notReachable

    var errorDescription: String? {
        switch self {
        case .badURL:             return "LM Studio: неверный URL"
        case .httpError(let c):   return "LM Studio: HTTP \(c)"
        case .invalidResponse:    return "LM Studio: неожиданный формат ответа"
        case .notReachable:       return "LM Studio недоступен — запусти и загрузи модель"
        }
    }
}

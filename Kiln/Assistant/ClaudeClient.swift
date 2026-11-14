import Foundation

/// A minimal Messages API client. Swift has no official Anthropic SDK, so this speaks HTTP directly.
struct ClaudeClient {
    static let defaultModel = "claude-opus-5-5"
    struct Model: Identifiable {
        let id: String
        let name: String
    }

    static let models = [
        Model(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
        Model(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
        Model(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
    ]
    static let efforts = ["low", "medium", "high", "xhigh"]

    enum Failure: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Add your Anthropic API key in Settings."
            case .http(let status, let message):
                return "Claude API error \(status): \(message)"
            case .invalidResponse:
                return "The Claude API returned a response Kiln could not read."
            }
        }
    }

    var apiKey: String
    var model: String
    var effort: String

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    /// Sends one Messages request and returns the response object.
    func send(system: String, messages: [JSONValue], tools: [JSONValue]) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw Failure.missingAPIKey }

        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": 16000,
            "system": .string(system),
            "messages": .array(messages),
            "tools": .array(tools),
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": .string(effort)],
            // Caches the tools, system prompt and conversation prefix between turns.
            "cache_control": ["type": "ephemeral"],
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        // If a safety classifier declines, retry on a suitable model instead of stopping.
        if model != "claude-haiku-5-5" {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = json?["error"]?["message"]?.stringValue ?? String(decoding: data, as: UTF8.self)
            throw Failure.http(http.statusCode, message)
        }
        guard let json else { throw Failure.invalidResponse }
        return json
    }
}

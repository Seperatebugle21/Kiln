import Foundation

/// A small GitHub REST client for the Git data API (refs, commits, trees and blobs).
struct GitHubClient: Sendable {
    var token: String?

    enum Failure: LocalizedError {
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(401, _):
                return "GitHub rejected the token. Check it in Settings."
            case .http(404, _):
                return "Not found on GitHub. Check the repository and branch, and that your token can access it."
            case .http(let status, let message):
                return "GitHub error \(status): \(message)"
            case .invalidResponse:
                return "GitHub returned a response Kiln could not read."
            }
        }

        var status: Int? {
            if case .http(let status, _) = self { return status }
            return nil
        }
    }

    private static let base = "https://api.github.com"

    func get(_ path: String) async throws -> JSONValue {
        try await send("GET", path, body: nil)
    }

    func send(_ method: String, _ path: String, body: JSONValue?) async throws -> JSONValue {
        guard let url = URL(string: Self.base + path) else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, json?["message"]?.stringValue ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        guard let json else { throw Failure.invalidResponse }
        return json
    }

    /// Accepts `owner/repo`, `github.com/owner/repo` or a full https URL (with or without `.git`).
    static func parseRepository(_ text: String) -> (owner: String, repo: String)? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where value.lowercased().hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.lowercased().hasPrefix("github.com/") { value = String(value.dropFirst("github.com/".count)) }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

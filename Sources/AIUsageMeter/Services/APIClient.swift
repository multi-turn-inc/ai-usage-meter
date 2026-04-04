import Foundation

// MARK: - API Protocol

protocol AIServiceAPI {
    func fetchUsage() async throws -> UsageData
}

// MARK: - API Error Types

enum APIError: LocalizedError {
    case invalidURL
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, message: String?)
    case decodingError(Error)
    case networkError(Error)
    case rateLimitExceeded(resetDate: Date?)
    case unauthorized
    case serverError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .missingAPIKey:
            return "API key is required"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message ?? "Unknown error")"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rateLimitExceeded(let resetDate):
            if let date = resetDate {
                return "Rate limit exceeded. Resets at \(date)"
            }
            return "Rate limit exceeded"
        case .unauthorized:
            return "Unauthorized. Please check your API key"
        case .serverError:
            return "Server error occurred"
        }
    }
}

// MARK: - Base API Client

class BaseAPIClient {
    let config: ServiceConfig

    init(config: ServiceConfig) {
        self.config = config
    }

    func performRequest(
        url: URL,
        headers: [String: String] = [:],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200...299:
                return (data, httpResponse)
            case 401:
                throw APIError.unauthorized
            case 429:
                let resetDate = parseRateLimitReset(from: httpResponse)
                throw APIError.rateLimitExceeded(resetDate: resetDate)
            case 500...599:
                throw APIError.serverError
            default:
                let message = String(data: data, encoding: .utf8)
                throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    func parseRateLimitReset(from response: HTTPURLResponse) -> Date? {
        if let resetTimestamp = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let timestamp = TimeInterval(resetTimestamp) {
            return Date(timeIntervalSince1970: timestamp)
        }
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter) {
            return Date(timeIntervalSinceNow: seconds)
        }
        return nil
    }
}

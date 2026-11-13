// APIService.swift
// StockPulse — Handles all backend API communication

import Foundation
import Combine

enum APIError: LocalizedError {
    case invalidURL
    case noData
    case decodingFailed(Error)
    case serverError(Int, String)
    case networkError(Error)
    case offline                    // device has no internet connection
    case timeout                    // request timed out

    var errorDescription: String? {
        switch self {
        case .invalidURL:                return "Invalid API URL"
        case .noData:                    return "No data received"
        case .decodingFailed(let e):     return "Decode error: \(e.localizedDescription)"
        case .serverError(let c, let m): return "Server error \(c): \(m)"
        case .networkError(let e):       return "Network error: \(e.localizedDescription)"
        case .offline:                   return "No internet connection"
        case .timeout:                   return "Request timed out — please try again"
        }
    }

    /// True for errors that are worth retrying automatically.
    var isRetryable: Bool {
        switch self {
        case .networkError, .timeout:    return true
        case .serverError(let c, _):     return c >= 500 || c == 429
        default:                         return false
        }
    }
}

final class APIService {

    // ── Change these to match your deployment ─────────────────────────────
    static let baseURL = "https://stockpulse-production-1a1f.up.railway.app"
    // Injected at build time from Secrets.xcconfig (gitignored) via Info.plist → ClientAPIKey.
    // Must match CLIENT_API_KEY on the backend. Note: anything shipped in the app binary is extractable.
    static var apiKey: String = Bundle.main.object(forInfoDictionaryKey: "ClientAPIKey") as? String ?? ""
    // ──────────────────────────────────────────────────────────────────────

    static let shared = APIService()
    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    // MARK: - Generic Request

    /// Performs a request with automatic retry on transient failures.
    /// Attempts: up to 3 total (initial + 2 retries) with 1 s / 2 s back-off.
    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        attempt: Int = 0
    ) async throws -> T {
        guard let url = URL(string: Self.baseURL + path) else {
            throw APIError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !Self.apiKey.isEmpty {
            req.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        }
        req.httpBody = body

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw APIError.noData }

            if !(200...299).contains(http.statusCode) {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw APIError.serverError(http.statusCode, msg)
            }

            return try decoder.decode(T.self, from: data)

        } catch let e as APIError {
            // Retry retryable errors (network glitches, 5xx) up to 2 more times
            if e.isRetryable && attempt < 2 {
                let delay: UInt64 = UInt64(attempt + 1) * 1_000_000_000   // 1 s, 2 s
                try await Task.sleep(nanoseconds: delay)
                return try await request(path: path, method: method, body: body, attempt: attempt + 1)
            }
            // Non-retryable or exhausted — send to Sentry and rethrow
            CrashReporter.shared.capture(
                error: e,
                context: ["path": path, "method": method, "attempt": attempt]
            )
            throw e

        } catch let e as DecodingError {
            let wrapped = APIError.decodingFailed(e)
            CrashReporter.shared.capture(
                error: wrapped,
                context: ["path": path, "type": String(describing: T.self)]
            )
            throw wrapped

        } catch let urlError as URLError {
            // Map URLError to more descriptive APIError cases
            let mapped: APIError
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                mapped = .offline
            case .timedOut:
                mapped = .timeout
            default:
                mapped = .networkError(urlError)
            }
            if mapped.isRetryable && attempt < 2 {
                let delay: UInt64 = UInt64(attempt + 1) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
                return try await request(path: path, method: method, body: body, attempt: attempt + 1)
            }
            CrashReporter.shared.capture(
                error: mapped,
                context: ["path": path, "attempt": attempt]
            )
            throw mapped

        } catch {
            let wrapped = APIError.networkError(error)
            CrashReporter.shared.capture(
                error: wrapped,
                context: ["path": path, "attempt": attempt]
            )
            throw wrapped
        }
    }

    // MARK: - Endpoints

    /// Fetch the full latest scan result
    func fetchLatestScan() async throws -> ScanResult {
        try await request(path: "/scan/latest")
    }

    /// Fetch top N tickers (optionally bullish only)
    func fetchTopTickers(limit: Int = 10, excludeNegative: Bool = false) async throws -> TopTickersResponse {
        let query = excludeNegative ? "?limit=\(limit)&exclude_negative=true" : "?limit=\(limit)"
        return try await request(path: "/scan/top\(query)")
    }

    /// Fetch tickers with negative/bearish traction
    func fetchNegativeTickers() async throws -> TopTickersResponse {
        try await request(path: "/scan/negative")
    }

    /// Fetch detail for a specific ticker
    func fetchTickerDetail(symbol: String) async throws -> TickerAnalysis {
        try await request(path: "/ticker/\(symbol.uppercased())")
    }

    /// Register device token for push notifications
    func registerDevice(token: String, sandbox: Bool = true) async throws {
        struct Body: Codable { let deviceToken: String; let sandbox: Bool }
        struct Response: Codable { let status: String }

        let body = try JSONEncoder().encode(Body(deviceToken: token, sandbox: sandbox))
        let _: Response = try await request(path: "/devices/register", method: "POST", body: body)
    }

    /// Manually trigger a scan (dev/testing)
    func triggerScan() async throws {
        struct Response: Codable { let status: String }
        let _: Response = try await request(path: "/scan/trigger", method: "POST")
    }

    /// Push the device's watchlist to the backend so it can send targeted alerts
    func updateWatchlist(token: String, tickers: [String]) async throws {
        struct Body: Encodable { let tickers: [String] }
        struct Response: Decodable { let status: String }
        let body = try JSONEncoder().encode(Body(tickers: tickers))
        let _: Response = try await request(
            path: "/devices/\(token)/watchlist",
            method: "POST",
            body: body
        )
    }

    /// Health check
    func healthCheck() async throws -> Bool {
        struct Health: Codable { let status: String }
        let h: Health = try await request(path: "/health")
        return h.status == "ok"
    }
}

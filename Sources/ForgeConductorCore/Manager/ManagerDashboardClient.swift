// ManagerDashboardClient.swift
// What: Provides a typed loopback client for an already-running persistent manager.
// How: URLSession requests decode status/settings and send JSON mutations to the
// validated local control endpoints with bounded timeouts.
// Why: The GUI can attach to the single manager owner instead of binding another server.

import Foundation

/// Native loopback client used by presentation processes that attach to the
/// one persistent manager instead of attempting to bind a second HTTP server.
public final class ManagerDashboardClient: @unchecked Sendable {
    public enum ClientError: Error, LocalizedError, Sendable {
        case invalidEndpoint
        case invalidResponse
        case rejected(status: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "Manager loopback endpoint is invalid"
            case .invalidResponse: "Manager returned a non-HTTP response"
            case .rejected(let status, let message):
                "Manager request failed with HTTP \(status): \(message)"
            }
        }
    }

    private let host: String
    private let port: Int
    private let session: URLSession

    public init(host: String, port: Int, session: URLSession = .shared) {
        self.host = host
        self.port = port
        self.session = session
    }

    public func status() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(method: "GET", path: "/api/manager/status"))
    }

    public func settings() async throws -> ManagerSettings {
        try ManagerSettings(dictionary: try await request(method: "GET", path: "/api/manager/settings"))
    }

    public func startService() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(method: "POST", path: "/api/manager/start", body: [:]))
    }

    public func stopService() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(method: "POST", path: "/api/manager/stop", body: [:]))
    }

    public func restartService() async throws -> ManagerStatus {
        try ManagerStatus(dictionary: try await request(method: "POST", path: "/api/manager/restart", body: [:]))
    }

    public func updateSettings(_ patch: ManagerSettingsPatch, apply: Bool = true) async throws -> ManagerSettings {
        let result = try await request(
            method: "POST",
            path: "/api/manager/settings",
            body: ["settings": patch.asConfigPatch(), "apply": apply]
        )
        return try ManagerSettings(dictionary: result)
    }

    private func request(
        method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard DashboardRequestPolicy.isConfiguredLoopbackHost(host) else {
            throw ClientError.invalidEndpoint
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url else { throw ClientError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSupport.data(from: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        let object = (try? JSONSupport.object(from: data)) ?? [:]
        guard (200...299).contains(http.statusCode) else {
            throw ClientError.rejected(
                status: http.statusCode,
                message: (object["message"] as? String) ?? String(data: data, encoding: .utf8) ?? "unknown"
            )
        }
        return object
    }
}

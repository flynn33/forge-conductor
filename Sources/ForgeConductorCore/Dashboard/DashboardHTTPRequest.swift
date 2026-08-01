// DashboardHTTPRequest.swift
// What: Models, parses, and validates requests accepted by the loopback dashboard.
// How: A bounded byte parser produces a typed request, then same-origin/host/content
// policy is evaluated before any route can perform a state-changing operation.
// Why: Protocol parsing and security policy remain independently testable from sockets.

import Foundation

/// A deliberately small HTTP/1.1 request model for the local telemetry server.
/// The parser owns all size and syntax checks before routing sees a request.
public struct DashboardHTTPRequest: Sendable, Equatable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method.uppercased()
        self.target = target
        self.headers = headers
        self.body = body
    }

    public subscript(header name: String) -> String? {
        headers[name.lowercased()]
    }

    public var isMutation: Bool {
        ["POST", "PUT", "PATCH", "DELETE"].contains(method)
    }
}

public enum DashboardHTTPRequestParseResult: Equatable {
    case incomplete
    case request(DashboardHTTPRequest)
    case rejected(status: Int, message: String)
}

public enum DashboardHTTPRequestParser {
    public static let maximumHeaderBytes = 32 * 1024
    public static let maximumBodyBytes = 1024 * 1024

    public static func parse(_ buffer: Data, streamComplete: Bool) -> DashboardHTTPRequestParseResult {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: delimiter) else {
            if buffer.count > maximumHeaderBytes {
                return .rejected(status: 431, message: "Request headers too large")
            }
            return streamComplete
                ? .rejected(status: 400, message: "Incomplete request")
                : .incomplete
        }

        guard headerEnd.lowerBound <= maximumHeaderBytes else {
            return .rejected(status: 431, message: "Request headers too large")
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .rejected(status: 400, message: "Request headers are not UTF-8")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .rejected(status: 400, message: "Missing request line")
        }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3,
              requestParts[2].hasPrefix("HTTP/1.") else {
            return .rejected(status: 400, message: "Invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .rejected(status: 400, message: "Invalid request header")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, headers[name] == nil else {
                return .rejected(status: 400, message: "Invalid or duplicate request header")
            }
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .rejected(status: 400, message: "Transfer-Encoding is not supported")
        }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else {
                return .rejected(status: 400, message: "Invalid Content-Length")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }
        guard contentLength <= maximumBodyBytes else {
            return .rejected(status: 413, message: "Request body too large")
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else {
            return streamComplete
                ? .rejected(status: 400, message: "Incomplete request body")
                : .incomplete
        }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        return .request(DashboardHTTPRequest(
            method: String(requestParts[0]),
            target: String(requestParts[1]),
            headers: headers,
            body: body
        ))
    }
}

/// Browser boundary for the dashboard. Telemetry reads remain local and simple;
/// state-changing requests must be same-origin JSON. LM Studio never crosses
/// this policy because its privileged connector is MCP over stdio.
public enum DashboardRequestPolicy {
    public static func rejection(
        for request: DashboardHTTPRequest,
        serverPort: UInt16
    ) -> (status: Int, message: String)? {
        guard let host = request[header: "host"], isLoopbackHost(host, port: serverPort) else {
            return (403, "Dashboard requests must target the local server")
        }
        guard request.isMutation else { return nil }

        let contentType = request[header: "content-type"]?.lowercased() ?? ""
        guard contentType.hasPrefix("application/json") else {
            return (415, "State-changing dashboard requests require application/json")
        }
        if let fetchSite = request[header: "sec-fetch-site"]?.lowercased(),
           fetchSite != "same-origin" && fetchSite != "none" {
            return (403, "Cross-origin dashboard requests are not allowed")
        }
        if let origin = request[header: "origin"],
           !allowedOrigins(port: serverPort).contains(normalizeOrigin(origin)) {
            return (403, "Cross-origin dashboard requests are not allowed")
        }
        return nil
    }

    public static func isConfiguredLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    private static func isLoopbackHost(_ value: String, port: UInt16) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedHosts(port: port).contains(normalized)
    }

    private static func allowedHosts(port: UInt16) -> Set<String> {
        [
            "localhost:\(port)",
            "127.0.0.1:\(port)",
            "[::1]:\(port)",
        ]
    }

    private static func allowedOrigins(port: UInt16) -> Set<String> {
        Set(allowedHosts(port: port).map { "http://\($0)" })
    }

    private static func normalizeOrigin(_ origin: String) -> String {
        origin.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

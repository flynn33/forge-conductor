// MCPServeVerifier.swift
// What: Performs a process-level MCP initialize and tools/list acceptance smoke.
// How: It launches a candidate binary with a clean role environment, exchanges bounded
// NDJSON frames, validates negotiated protocol and role identity, then terminates it.
// Why: Deployment must fail closed before registering a binary that a host cannot use.

import Foundation
import Darwin

/// Verifies a Forge binary can speak MCP stdio (initialize + tools/list).
/// Used after Deploy so product path failures are caught before the operator opens LM Studio.
public enum MCPServeVerifier {
    public static let minimumToolCount = 20
    private static let maximumOutputBytes = 4 * 1_024 * 1_024
    public static let requiredContinuityTools: Set<String> = [
        "session_checkpoint",
        "session_handoff",
        "context_get",
        "context_list",
    ]

    public struct Result: Sendable, Equatable {
        public var ok: Bool
        public var protocolVersion: String?
        public var serverName: String?
        public var toolCount: Int
        public var toolNames: [String]
        public var detail: String
        public var durationMs: Int

        public init(
            ok: Bool,
            protocolVersion: String?,
            serverName: String?,
            toolCount: Int,
            toolNames: [String] = [],
            detail: String,
            durationMs: Int
        ) {
            self.ok = ok
            self.protocolVersion = protocolVersion
            self.serverName = serverName
            self.toolCount = toolCount
            self.toolNames = toolNames
            self.detail = detail
            self.durationMs = durationMs
        }
    }

    /// Spawn `binary serve`, send LM Studio-style initialize (2025-11-25) + tools/list.
    public static func verify(
        binary: URL,
        home: URL,
        role: String = "primary",
        timeoutSec: TimeInterval = 8
    ) throws -> Result {
        let start = Date()
        let connectorRole = LMStudioConnectorRole(environmentValue: role)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return Result(
                ok: false,
                protocolVersion: nil,
                serverName: nil,
                toolCount: 0,
                toolNames: [],
                detail: "not executable: \(binary.path)",
                durationMs: 0
            )
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["serve"]
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        proc.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "FORGE_CONDUCTOR_HOME": home.path,
            "FORGE_MCP_ROLE": connectorRole.rawValue,
            "TMPDIR": NSTemporaryDirectory(),
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        setNonblocking(stdout.fileHandleForReading)
        setNonblocking(stderr.fileHandleForReading)

        // LM Studio client shape (NDJSON).
        let initMsg =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"forge-deploy-verify","version":"1.0.0"}}}"#
            + "\n"
        let inited = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
        let tools = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"# + "\n"
        stdin.fileHandleForWriting.write(Data(initMsg.utf8))
        stdin.fileHandleForWriting.write(Data(inited.utf8))
        stdin.fileHandleForWriting.write(Data(tools.utf8))
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeoutSec)
        var outData = Data()
        var errData = Data()
        var frames: [[String: Any]] = []
        while Date() < deadline {
            drain(stdout.fileHandleForReading, into: &outData, limit: maximumOutputBytes)
            drain(stderr.fileHandleForReading, into: &errData, limit: 64 * 1_024)
            frames = decodeFrames(outData)
            if proc.isRunning == false { break }
            // Do not terminate on the initialize capability's "tools" key;
            // wait for the complete tools/list response (id 2).
            if frames.contains(where: { numericID($0["id"]) == 2 }) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
        }
        let terminationDeadline = Date().addingTimeInterval(1)
        while proc.isRunning, Date() < terminationDeadline {
            drain(stdout.fileHandleForReading, into: &outData, limit: maximumOutputBytes)
            drain(stderr.fileHandleForReading, into: &errData, limit: 64 * 1_024)
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning {
            _ = Darwin.kill(proc.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while proc.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        drain(stdout.fileHandleForReading, into: &outData, limit: maximumOutputBytes)
        drain(stderr.fileHandleForReading, into: &errData, limit: 64 * 1_024)
        let errTail = String(data: errData, encoding: .utf8) ?? ""
        let ms = Int(Date().timeIntervalSince(start) * 1000)

        // Accept only standards-compliant newline-delimited MCP output. This
        // deliberately prevents Forge's verifier from self-certifying LSP-style
        // Content-Length responses that LM Studio rejects.
        frames = decodeFrames(outData)
        let ndjsonOnly = isValidNDJSON(outData)
        var protocolVersion: String?
        var serverName: String?
        var toolCount = 0
        var toolNames: [String] = []
        var envelopeOK = false
        var descriptorsOK = false
        if let initialize = frames.first(where: { numericID($0["id"]) == 1 }),
           initialize["jsonrpc"] as? String == "2.0",
           initialize["error"] == nil,
           let result = initialize["result"] as? [String: Any] {
            protocolVersion = result["protocolVersion"] as? String
            serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
            envelopeOK = true
        }
        if let list = frames.first(where: { numericID($0["id"]) == 2 }),
           list["jsonrpc"] as? String == "2.0",
           list["error"] == nil,
           let result = list["result"] as? [String: Any],
           let tools = result["tools"] as? [[String: Any]] {
            toolCount = tools.count
            toolNames = tools.compactMap { $0["name"] as? String }.sorted()
            let uniqueNames = Set(toolNames)
            descriptorsOK = toolNames.count == toolCount
                && uniqueNames.count == toolCount
                && tools.allSatisfy { descriptor in
                    guard let name = descriptor["name"] as? String, !name.isEmpty,
                          let description = descriptor["description"] as? String, !description.isEmpty,
                          let schema = descriptor["inputSchema"] as? [String: Any] else {
                        return false
                    }
                    return schema["type"] as? String == "object"
                }
        }

        let identityOK = serverName == connectorRole.serverID
        let protocolOK = protocolVersion.map(MCPServer.supportedProtocolVersions.contains) ?? false
        let missingContinuityTools = Self.requiredContinuityTools.subtracting(toolNames).sorted()
        let ok = ndjsonOnly
            && envelopeOK
            && protocolOK
            && toolCount >= minimumToolCount
            && descriptorsOK
            && identityOK
            && missingContinuityTools.isEmpty
        var detail: String
        if ok {
            detail = "initialize ok protocol=\(protocolVersion ?? "?") tools=\(toolCount) in \(ms)ms"
        } else {
            detail = "handshake incomplete role=\(connectorRole.rawValue) server=\(serverName ?? "nil") tools=\(toolCount) ndjson=\(ndjsonOnly) envelope=\(envelopeOK) descriptors=\(descriptorsOK) missing_continuity=\(missingContinuityTools.joined(separator: ",")) protocol=\(protocolVersion ?? "nil") stderr=\(errTail.prefix(200))"
        }

        return Result(
            ok: ok,
            protocolVersion: protocolVersion,
            serverName: serverName,
            toolCount: toolCount,
            toolNames: toolNames,
            detail: detail,
            durationMs: ms
        )
    }

    private static func numericID(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private static func decodeFrames(_ data: Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if !line.isEmpty, let object = try? JSONSupport.object(from: line) {
                messages.append(object)
            }
        }
        return messages
    }

    private static func isValidNDJSON(_ data: Data) -> Bool {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let object = try? JSONSupport.object(from: line) else { return false }
            return object["jsonrpc"] as? String == "2.0"
        }
    }

    private static func setNonblocking(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 {
            _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private static func drain(_ handle: FileHandle, into data: inout Data, limit: Int) {
        guard data.count < limit else { return }
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: min(16_384, limit - data.count))
        while !buffer.isEmpty {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(buffer, count: count)
                if data.count >= limit { return }
                buffer = [UInt8](repeating: 0, count: min(16_384, limit - data.count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            return
        }
    }
}

/// Foundation `Process` adapter behind the deployment verifier port.
public struct NativeMCPServeVerifier: MCPServeVerifying {
    public init() {}

    public func verify(
        binary: URL,
        home: URL,
        role: LMStudioConnectorRole,
        timeoutSec: TimeInterval
    ) throws -> MCPServeVerifier.Result {
        try MCPServeVerifier.verify(
            binary: binary,
            home: home,
            role: role.rawValue,
            timeoutSec: timeoutSec
        )
    }
}

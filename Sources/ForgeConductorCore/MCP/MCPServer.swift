// MCPServer.swift
// What: Implements Forge's JSON-RPC MCP server over standard input/output.
// How: A bounded stream reader accepts supported framing, dispatches requests to
// ForgeApp services, and emits newline-delimited responses with role-specific identity.
// Why: The host-facing protocol remains isolated from tools and application composition.

import Foundation
import Darwin

/// JSON-RPC 2.0 MCP server over stdio for **LM Studio** (local models).
public final class MCPServer: @unchecked Sendable {
    private let app: ForgeApp
    private let clientID: ClientID
    private let role: LMStudioConnectorRole
    private let deploymentID: String
    private let lock = NSLock()

    public init(
        app: ForgeApp,
        clientID: ClientID = ClientID(),
        role: LMStudioConnectorRole = LMStudioConnectorRole(
            environmentValue: ProcessInfo.processInfo.environment["FORGE_MCP_ROLE"]
        )
    ) {
        self.app = app
        self.clientID = clientID
        self.role = role
        self.deploymentID = ProcessInfo.processInfo.environment["FORGE_DEPLOYMENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Blocking serve loop: read newline-delimited or Content-Length framed messages from stdin.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) throws {
        // MCP hosts (LM Studio) attach via pipes. Fully-buffered stdout delays
        // initialize responses until the buffer fills → host reports plugin timeout (~60s).
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)

        app.diagnostics.info("mcp_serve_start", [
            "client_id": clientID.rawValue,
            "role": role.rawValue,
            "host_kind": role.hostKind,
            "deployment_id": deploymentID,
        ])
        // Best-effort presence; never block MCP handshake on a locked GUI store.
        try? app.store.presenceUpsert(
            clientID: presenceID,
            hostKind: role.hostKind,
            pid: ProcessInfo.processInfo.processIdentifier,
            cwd: FileManager.default.currentDirectoryPath
        )

        var lastPresence = Date.distantPast
        let reader = MCPStreamReader(handle: input)
        while let message = try reader.readMessage() {
            // Refresh presence while the stdio session is active (dashboard TTL ~45s).
            let now = Date()
            if now.timeIntervalSince(lastPresence) >= 15 {
                try? app.store.presenceUpsert(
                    clientID: presenceID,
                    hostKind: role.hostKind,
                    pid: ProcessInfo.processInfo.processIdentifier,
                    cwd: FileManager.default.currentDirectoryPath
                )
                lastPresence = now
            }
            let response = handle(message)
            if let response {
                try write(response, to: output)
            }
        }
        try? app.store.presenceDelete(clientID: presenceID)
        app.diagnostics.info("mcp_serve_end", [
            "client_id": clientID.rawValue,
            "role": role.rawValue,
            "deployment_id": deploymentID,
        ])
    }

    // MARK: - Message handling

    public func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        let method = message["method"] as? String
        // Notification (no id): ignore result
        let isNotification = id == nil || id is NSNull

        guard let method else {
            if isNotification { return nil }
            return errorResponse(id: id, code: -32600, message: "Invalid Request: missing method")
        }

        // Notifications we acknowledge silently
        if method == "notifications/initialized" || method.hasPrefix("notifications/") {
            return nil
        }

        do {
            switch method {
            case "initialize":
                // Distinct names so LM Studio can list primary vs fail-forward fallback.
                let serverName = role.serverID
                // Negotiate protocol: LM Studio 0.4.x sends 2025-11-25; older clients send 2024-11-05.
                // Echo a version we support so the host does not hang ~60s on mismatch.
                let params = message["params"] as? [String: Any] ?? [:]
                let requested = (params["protocolVersion"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let negotiated = Self.negotiateProtocolVersion(requested)
                app.diagnostics.info("mcp_initialize", [
                    "requested": requested.isEmpty ? "(none)" : requested,
                    "negotiated": negotiated,
                    "server": serverName,
                    "deployment_id": deploymentID,
                ], category: .mcp)
                return ok(id: id, result: [
                    "protocolVersion": negotiated,
                    "capabilities": [
                        "tools": ["listChanged": false] as [String: Any],
                    ] as [String: Any],
                    "serverInfo": [
                        "name": serverName,
                        "version": ForgeApp.version,
                    ] as [String: Any],
                ])
            case "ping":
                return ok(id: id, result: [:] as [String: Any])
            case "tools/list":
                let tools = toolDescriptors()
                app.diagnostics.info("mcp_tools_list", [
                    "count": "\(tools.count)",
                    "client_id": clientID.rawValue,
                    "deployment_id": deploymentID,
                ], category: .mcp)
                return ok(id: id, result: ["tools": tools])
            case "tools/call":
                let params = message["params"] as? [String: Any] ?? [:]
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                app.diagnostics.info("mcp_tools_call", [
                    "tool": name,
                    "client_id": clientID.rawValue,
                ], category: .mcp)
                let result = try app.tools.call(name: name, arguments: arguments, clientID: clientID)
                let text = (try? JSONSupport.string(from: result.payload)) ?? "{\"ok\":false}"
                return ok(id: id, result: [
                    "content": [
                        ["type": "text", "text": text] as [String: Any],
                    ],
                    "isError": result.isError || !result.ok,
                    "structuredContent": result.payload,
                ])
            case "resources/list":
                return ok(id: id, result: ["resources": [] as [Any]])
            case "prompts/list":
                return ok(id: id, result: ["prompts": [] as [Any]])
            default:
                if isNotification { return nil }
                return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }
        } catch {
            if isNotification { return nil }
            return errorResponse(id: id, code: -32000, message: "\(error)")
        }
    }

    private var presenceID: String {
        "\(clientID.rawValue):\(role.rawValue)"
    }

    private func toolDescriptors() -> [[String: Any]] {
        app.tools.toolNames.map { name in
            [
                "name": name,
                "description": Self.descriptions[name] ?? "Forge-Conductor tool: \(name)",
                "inputSchema": Self.schema(for: name),
            ]
        }
    }

    private static let descriptions: [String: String] = [
        "forge_status": "Runtime status: home, agents, open sessions, tools.",
        "agent_list": "List specialist agent playbooks.",
        "agent_get": "Get a specialist agent playbook by id.",
        "agent_context": "Alias of agent_get — full playbook body.",
        "agent_recommend": "Recommend a specialist agent for a task description.",
        "agent_run_start": "Start a durable specialist session (supersedes prior open sessions).",
        "agent_run_status": "Status of an agent session; reminds host to complete open runs.",
        "agent_run_complete": "Close a session with a report matching output_schema.",
        "session_checkpoint": "Soft-save context + open agent sessions for continuity (continue working).",
        "session_handoff": "Finalize context/agent handoff for a new chat; returns resume_seed. Prefer before context is full.",
        "context_get": "Load latest (or id) handoff packet — call first in every new chat bootstrap.",
        "context_list": "List recent context handoff packets.",
        "fs_read": "Read a UTF-8 text file.",
        "fs_write": "Write a UTF-8 text file.",
        "fs_edit": "Replace occurrences of old with new in a file.",
        "fs_list": "List directory entries.",
        "fs_glob": "Find files by name pattern under a path.",
        "fs_mkdir": "Create a directory.",
        "fs_delete": "Delete a file or directory.",
        "fs_move": "Move/rename a path.",
        "shell_exec": "Run a bash command with timeout.",
        "git_status": "git status --porcelain.",
        "git_diff": "git diff (optional staged).",
        "git_log": "git log --oneline.",
        "git_add": "git add path or -A.",
        "git_commit": "git commit -m message.",
        "pdf_write": "Write a PDF from markdown-ish text (stdlib, no pandoc).",
        "pdf_from_file": "Convert a local markdown/text file to PDF.",
        "search_text": "Recursive text search (grep).",
    ]

    private static func schema(for name: String) -> [String: Any] {
        let object: [String: Any] = ["type": "object"]
        switch name {
        case "agent_run_start":
            return [
                "type": "object",
                "properties": [
                    "agent_id": ["type": "string"] as [String: Any],
                    "goal": ["type": "string"] as [String: Any],
                    "cwd": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["agent_id", "goal"],
            ]
        case "agent_run_status", "agent_run_complete":
            return [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string"] as [String: Any],
                    "report": ["type": "object"] as [String: Any],
                ] as [String: Any],
                "required": ["session_id"],
            ]
        case "agent_get", "agent_context":
            return [
                "type": "object",
                "properties": ["agent_id": ["type": "string"] as [String: Any]] as [String: Any],
                "required": ["agent_id"],
            ]
        case "agent_recommend":
            return [
                "type": "object",
                "properties": ["task": ["type": "string"] as [String: Any]] as [String: Any],
                "required": ["task"],
            ]
        case "session_checkpoint", "session_handoff":
            return [
                "type": "object",
                "properties": [
                    "goal": ["type": "string"] as [String: Any],
                    "status": ["type": "string"] as [String: Any],
                    "project_slug": ["type": "string"] as [String: Any],
                    "cwd": ["type": "string"] as [String: Any],
                    "narrative": ["type": "string"] as [String: Any],
                    "summary": ["type": "string", "description": "Alias for narrative"] as [String: Any],
                    "next_actions": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "blockers": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "key_files": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "decisions": ["type": "array", "items": ["type": "string"] as [String: Any]] as [String: Any],
                    "chat_label": ["type": "string"] as [String: Any],
                    "handoff_id": ["type": "string", "description": "Update an existing packet"] as [String: Any],
                    "resume_seed": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
            ]
        case "context_get":
            return [
                "type": "object",
                "properties": [
                    "handoff_id": ["type": "string"] as [String: Any],
                    "id": ["type": "string"] as [String: Any],
                    "resume_ready": ["type": "boolean", "description": "Prefer latest resume-ready packet"] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
            ]
        case "context_list":
            return [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer"] as [String: Any],
                ] as [String: Any],
                "required": [] as [String],
            ]
        case "fs_read", "fs_list", "fs_delete", "fs_mkdir":
            return [
                "type": "object",
                "properties": ["path": ["type": "string"] as [String: Any]] as [String: Any],
                "required": name == "fs_list" ? [] as [String] : ["path"],
            ]
        case "fs_write":
            return [
                "type": "object",
                "properties": [
                    "path": ["type": "string"] as [String: Any],
                    "content": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["path", "content"],
            ]
        case "shell_exec":
            return [
                "type": "object",
                "properties": [
                    "command": ["type": "string"] as [String: Any],
                    "cwd": ["type": "string"] as [String: Any],
                    "timeout_sec": ["type": "number"] as [String: Any],
                ] as [String: Any],
                "required": ["command"],
            ]
        case "pdf_write":
            return [
                "type": "object",
                "properties": [
                    "path": ["type": "string"] as [String: Any],
                    "content": ["type": "string"] as [String: Any],
                    "title": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["path", "content"],
            ]
        case "pdf_from_file":
            return [
                "type": "object",
                "properties": [
                    "source_path": ["type": "string"] as [String: Any],
                    "dest_path": ["type": "string"] as [String: Any],
                    "title": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["source_path"],
            ]
        case "search_text":
            return [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string"] as [String: Any],
                    "path": ["type": "string"] as [String: Any],
                ] as [String: Any],
                "required": ["pattern"],
            ]
        default:
            return object.merging(["properties": [:] as [String: Any], "additionalProperties": true]) { _, n in n }
        }
    }

    /// Protocol versions we implement (tools list/call). Prefer the client's request when known.
    public static let supportedProtocolVersions: [String] = [
        "2025-11-25",
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    public static func negotiateProtocolVersion(_ requested: String) -> String {
        let r = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return supportedProtocolVersions[0] }
        if supportedProtocolVersions.contains(r) { return r }
        // Unknown future version: advertise newest we support (hosts typically accept).
        return supportedProtocolVersions[0]
    }

    private func ok(id: Any?, result: [String: Any]) -> [String: Any] {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { resp["id"] = id }
        return resp
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
        if let id { resp["id"] = id } else { resp["id"] = NSNull() }
        return resp
    }

    private func write(_ object: [String: Any], to handle: FileHandle) throws {
        let packet = try MCPStdioTransport.encode(object)
        lock.lock()
        defer { lock.unlock() }
        // One compact JSON-RPC message per line is the MCP stdio transport.
        try handle.write(contentsOf: packet)
        if handle.fileDescriptor >= 0 {
            fflush(stdout)
        }
    }
}

/// MCP stdio wire encoder. The specification requires one compact JSON-RPC
/// message per line; Content-Length headers belong to LSP, not MCP stdio.
public enum MCPStdioTransport {
    public static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSupport.data(from: object)
        data.append(0x0A)
        return data
    }
}

// MARK: - Stream reader

public final class MCPStreamReader {
    private let handle: FileHandle
    private let maximumMessageBytes: Int
    private var buffer = Data()

    public init(handle: FileHandle, maximumMessageBytes: Int = 4 * 1024 * 1024) {
        self.handle = handle
        self.maximumMessageBytes = maximumMessageBytes
    }

    public func readMessage() throws -> [String: Any]? {
        while true {
            if let msg = try extractMessage() {
                return msg
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF
                if buffer.isEmpty { return nil }
                // try parse remaining as NDJSON line
                if let msg = try extractMessage(forceLine: true) {
                    return msg
                }
                return nil
            }
            buffer.append(chunk)
            if buffer.count > maximumMessageBytes {
                throw MCPStreamError.messageTooLarge(maximumMessageBytes)
            }
        }
    }

    private func extractMessage(forceLine: Bool = false) throws -> [String: Any]? {
        // Content-Length framing
        if let range = buffer.range(of: Data("\r\n\r\n".utf8))
            ?? buffer.range(of: Data("\n\n".utf8)) {
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            if let lenLine = header.split(separator: "\n").map(String.init)
                .first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                let parts = lenLine.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                    guard length >= 0, length <= maximumMessageBytes else {
                        throw MCPStreamError.messageTooLarge(maximumMessageBytes)
                    }
                    let bodyStart = range.upperBound
                    let needed = buffer.distance(from: bodyStart, to: buffer.endIndex)
                    if needed < length { return nil }
                    let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                    let body = buffer.subdata(in: bodyStart..<bodyEnd)
                    buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                    return try JSONSupport.object(from: body)
                }
            }
        }

        // NDJSON fallback
        if let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty || line == Data([0x0D]) { return try extractMessage(forceLine: forceLine) }
            let trimmed = line.drop(while: { $0 == 0x0D })
            if trimmed.isEmpty { return try extractMessage(forceLine: forceLine) }
            return try JSONSupport.object(from: Data(trimmed))
        }
        if forceLine, !buffer.isEmpty {
            let body = buffer
            buffer.removeAll()
            return try JSONSupport.object(from: body)
        }
        return nil
    }
}

public enum MCPStreamError: Error, LocalizedError, Sendable {
    case messageTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .messageTooLarge(let maximum):
            "MCP message exceeds the \(maximum)-byte limit"
        }
    }
}

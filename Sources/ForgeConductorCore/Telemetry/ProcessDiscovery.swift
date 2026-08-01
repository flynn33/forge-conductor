// ProcessDiscovery.swift
// What: Discovers Forge, manager, LM Studio, model, and MCP processes.
// How: Native process enumeration classifies executable paths and arguments with strict
// allow/deny rules, deduplicates PIDs, and returns bounded role-specific collections.
// Why: Product health must not count unrelated local orchestration processes.

import Foundation
import Darwin

/// Live process discovery for **LM Studio local-model** workflows.
///
/// Surfaces:
/// - LM Studio host app
/// - Local model backends (llama.cpp / mlx under `~/.lmstudio`)
/// - Forge Conductor Swift MCP: `forge-conductor serve` (from `~/.lmstudio/mcp.json`)
///
/// Explicitly **not** Claude Code orchestration, CCDT, `~/.claude/local-mcp`,
/// or legacy Python/bash `forge-serve` wrappers.
public enum ProcessDiscovery {
    static let unknownMCPHostKind = "mcp-stdio-unknown"
    static let unknownMCPLabel = "Forge MCP (role unknown)"

    /// Pure classification of this product's executable modes.
    ///
    /// Keeping argv classification separate from process enumeration makes the
    /// app-bundle `serve` path testable without depending on the host process list.
    enum ForgeCommandKind: Equatable {
        case unrelated
        case gui
        case manager
        case serve
        case legacy
    }

    public struct Snapshot: Sendable {
        public var managerPIDs: [Int32] = []
        public var servePIDs: [Int32] = []
        public var supervisePIDs: [Int32] = []
        /// Host + MCP processes relevant to LM Studio / Forge.
        public var mcpProcesses: [MCPProcess] = []
        public var lmStudioPIDs: [Int32] = []
        public var modelBackendPIDs: [Int32] = []
    }

    public struct MCPProcess: Sendable {
        public let pid: Int32
        public let label: String
        public let hostKind: String
        public let command: String
    }

    struct ConnectorProcessIdentity: Equatable {
        let role: LMStudioConnectorRole?
        let label: String
        let hostKind: String
    }

    public static func pidAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    public static func scan() -> Snapshot {
        var snap = Snapshot()
        if ProcessInfo.processInfo.environment["FORGE_SKIP_PS"] == "1" {
            return snap
        }

        let entries = listProcesses()
        var seen = Set<Int32>()

        for entry in entries {
            let pid = entry.pid
            let path = entry.path
            let args = entry.args
            let cmd = args.isEmpty ? path : (path + " " + args.joined(separator: " "))
            guard pid > 0, !seen.contains(pid) else { continue }

            // Always drop Claude / CCDT / foreign orchestration.
            if isExcludedForeignProject(path: path, cmd: cmd) {
                seen.insert(pid)
                continue
            }

            // LM Studio host
            if isLMStudio(path: path, cmd: cmd) {
                snap.lmStudioPIDs.append(pid)
                snap.mcpProcesses.append(MCPProcess(
                    pid: pid,
                    label: "LM Studio",
                    hostKind: "lm-studio-host",
                    command: String(cmd.prefix(240))
                ))
                seen.insert(pid)
                continue
            }

            // Local model inference backends (llama.cpp / mlx shipped with LM Studio)
            if isModelBackend(path: path, cmd: cmd) {
                snap.modelBackendPIDs.append(pid)
                let label = (path as NSString).lastPathComponent
                snap.mcpProcesses.append(MCPProcess(
                    pid: pid,
                    label: label,
                    hostKind: "model-backend",
                    command: String(cmd.prefix(240))
                ))
                seen.insert(pid)
                continue
            }

            switch classifyForgeCommand(path: path, arguments: args) {
            case .manager:
                snap.managerPIDs.append(pid)
                seen.insert(pid)
                continue
            case .serve:
                let identity = connectorProcessIdentity(
                    environmentRole: entry.connectorRole
                )
                snap.servePIDs.append(pid)
                snap.mcpProcesses.append(MCPProcess(
                    pid: pid,
                    label: identity.label,
                    hostKind: identity.hostKind,
                    command: String(cmd.prefix(240))
                ))
                seen.insert(pid)
                continue
            case .gui, .legacy:
                seen.insert(pid)
                continue
            case .unrelated:
                break
            }
        }

        return snap
    }

    /// Counts only live Forge MCP stdio processes. Model inference backends are
    /// intentionally excluded, while both primary and fallback stdio roles count.
    static func mcpExternalProcessCount(_ processes: [MCPProcess]) -> Int {
        return Set(
            processes.lazy
                .filter { isForgeMCPStdioHostKind($0.hostKind) }
                .map(\.pid)
        ).count
    }

    // MARK: - Classification

    /// Resolves the role from LM Studio's per-registration environment. Primary
    /// and fallback share an executable and argv, so absent or invalid role
    /// evidence must remain unknown rather than being attributed to primary.
    static func connectorProcessIdentity(
        environmentRole: String?
    ) -> ConnectorProcessIdentity {
        let normalized = environmentRole?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized,
              let role = LMStudioConnectorRole(rawValue: normalized) else {
            return ConnectorProcessIdentity(
                role: nil,
                label: unknownMCPLabel,
                hostKind: unknownMCPHostKind
            )
        }
        return ConnectorProcessIdentity(
            role: role,
            label: role.serverID,
            hostKind: role.hostKind
        )
    }

    static func isForgeMCPStdioHostKind(_ hostKind: String) -> Bool {
        hostKind == unknownMCPHostKind
            || LMStudioConnectorRole.allCases.contains { $0.hostKind == hostKind }
    }

    /// Classifies only Forge Conductor executables from their exact argv.
    ///
    /// The app executable is a valid stdio server only when its first argument
    /// selects an MCP-serving mode. A double-clicked/no-argument app remains GUI,
    /// and manager invocations remain control-plane processes.
    static func classifyForgeCommand(path: String, arguments: [String]) -> ForgeCommandKind {
        let command = ([path] + arguments).joined(separator: " ")
        if isLegacyForgeServeLauncher(path: path, cmd: command) {
            return .legacy
        }

        let leaf = (path as NSString).lastPathComponent
        let isCLI = leaf == "forge-conductor"
        let isAppExecutable = leaf == "Forge Conductor"
            && path.contains("Forge Conductor.app/Contents/MacOS/")
        guard isCLI || isAppExecutable else {
            return .unrelated
        }

        switch arguments.first {
        case "manager":
            return .manager
        case "serve", "mcp-serve", "mcp":
            return .serve
        case "supervise":
            return .legacy
        default:
            return .gui
        }
    }

    /// Splits `ps` command text while preserving this product's app-bundle
    /// executable path, whose bundle and executable names both contain spaces.
    static func splitPSCommand(_ command: String) -> (path: String, arguments: [String]) {
        var normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = normalized.hasPrefix("\"")
        if quoted {
            normalized.removeFirst()
        }

        let bundleSuffix = "/Forge Conductor.app/Contents/MacOS/Forge Conductor"
        if let range = normalized.range(of: bundleSuffix) {
            let prefix = normalized[..<range.lowerBound]
            if prefix.hasPrefix("/") && !prefix.contains(where: \.isWhitespace) {
                let path = String(normalized[..<range.upperBound])
                var remainder = String(normalized[range.upperBound...])
                if quoted, remainder.hasPrefix("\"") {
                    remainder.removeFirst()
                }
                let arguments = remainder.split(whereSeparator: \.isWhitespace).map(String.init)
                return (path, arguments)
            }
        }

        let parts = normalized
            .split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            .map(String.init)
        return (parts.first ?? normalized, Array(parts.dropFirst()))
    }

    private static func isLMStudio(path: String, cmd: String) -> Bool {
        let hay = path + " " + cmd
        if hay.contains("LM Studio.app") { return true }
        if hay.contains("/LM Studio") { return true }
        let leaf = (path as NSString).lastPathComponent
        if leaf == "LM Studio" { return true }
        return false
    }

    private static func isModelBackend(path: String, cmd: String) -> Bool {
        let hay = (path + " " + cmd).lowercased()
        if hay.contains("/.lmstudio/") {
            if hay.contains("llama") || hay.contains("mlx") || hay.contains("ggml") {
                return true
            }
        }
        let leaf = (path as NSString).lastPathComponent.lowercased()
        if leaf.contains("llama-server") || leaf.contains("llama.cpp") { return true }
        if leaf.hasPrefix("mlx") && hay.contains("lmstudio") { return true }
        return false
    }

    private static func isLegacyForgeServeLauncher(path: String, cmd: String) -> Bool {
        LMStudioEnvironment.legacyShellLauncherPath(path)
            || LMStudioEnvironment.legacyShellLauncherPath(cmd)
    }

    /// Claude Code, CCDT, and other non–LM-Studio orchestration — never surface.
    private static func isExcludedForeignProject(path: String, cmd: String) -> Bool {
        let hay = (path + " " + cmd).lowercased()
        if hay.contains("ccdt") { return true }
        if hay.contains("project-continuity") { return true }
        if hay.contains("/.claude/") { return true }
        if hay.contains("claude/local-mcp") { return true }
        if hay.contains("local-mcp/bin/ccdt") { return true }
        // Claude Code desktop helpers are not this product.
        if hay.contains("claude.app") && !hay.contains("forge") { return true }
        return false
    }

    // MARK: - libproc enumeration

    private struct ProcEntry {
        var pid: Int32
        var path: String
        var args: [String]
        var connectorRole: String?
    }

    struct ProcessInvocation: Equatable {
        var arguments: [String]
        var connectorRole: String?

        static let empty = ProcessInvocation(arguments: [], connectorRole: nil)
    }

    private static func listProcesses() -> [ProcEntry] {
        let estimated = max(proc_listallpids(nil, 0), 256)
        var pids = [Int32](repeating: 0, count: Int(estimated) + 128)
        let filled = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(buf.count * MemoryLayout<Int32>.size))
        }
        if filled <= 0 {
            return listProcessesViaPS()
        }
        var count = Int(filled)
        if count > pids.count, count % MemoryLayout<Int32>.size == 0 {
            count = count / MemoryLayout<Int32>.size
        }
        count = min(count, pids.count)

        var out: [ProcEntry] = []
        out.reserveCapacity(min(count, 1024))
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            guard let path = pidPath(pid), !path.isEmpty else { continue }
            let invocation = pidInvocation(pid)
            out.append(ProcEntry(
                pid: pid,
                path: path,
                args: invocation.arguments,
                connectorRole: invocation.connectorRole
            ))
        }
        if out.count < 8 {
            let viaPS = listProcessesViaPS()
            if viaPS.count > out.count { return viaPS }
        }
        return out
    }

    private static func pidPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        let end = buf.firstIndex(of: 0) ?? min(Int(n), buf.count)
        return String(
            decoding: buf[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func pidInvocation(_ pid: Int32) -> ProcessInvocation {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size < 1024 * 1024 else {
            return .empty
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 4 else {
            return .empty
        }
        return decodeProcessInvocation(
            Array(buffer.prefix(min(Int(size), buffer.count)))
        )
    }

    static func decodeProcessInvocation(_ buffer: [UInt8]) -> ProcessInvocation {
        guard buffer.count > 4 else { return .empty }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return .empty }

        var idx = 4
        while idx < buffer.count, buffer[idx] != 0 { idx += 1 }
        while idx < buffer.count, buffer[idx] == 0 { idx += 1 }

        var args: [String] = []
        for _ in 0..<Int(argc) {
            if idx >= buffer.count { break }
            let start = idx
            while idx < buffer.count, buffer[idx] != 0 { idx += 1 }
            if start < idx {
                let slice = buffer[start..<idx]
                if let s = String(bytes: slice, encoding: .utf8), !s.isEmpty {
                    args.append(s)
                }
            }
            idx += 1
        }

        var connectorRole: String?
        while idx < buffer.count {
            while idx < buffer.count, buffer[idx] == 0 { idx += 1 }
            guard idx < buffer.count else { break }
            let start = idx
            while idx < buffer.count, buffer[idx] != 0 { idx += 1 }
            let value = String(decoding: buffer[start..<idx], as: UTF8.self)
            let prefix = "FORGE_MCP_ROLE="
            if value.hasPrefix(prefix) {
                connectorRole = String(value.dropFirst(prefix.count))
                break
            }
        }

        return ProcessInvocation(
            arguments: Array(args.dropFirst()),
            connectorRole: connectorRole
        )
    }

    private static func listProcessesViaPS() -> [ProcEntry] {
        let result = try? ProcessRunner().run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,command="],
            timeoutSec: 3.0
        )
        guard let result, !result.timedOut, !result.stdout.isEmpty else { return [] }
        var out: [ProcEntry] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            let cmd = String(trimmed[trimmed.index(after: space)...])
            let invocation = splitPSCommand(cmd)
            out.append(ProcEntry(
                pid: pid,
                path: invocation.path,
                args: invocation.arguments,
                connectorRole: nil
            ))
        }
        return out
    }
}

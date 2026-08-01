// GitToolPack.swift
// What: Adapts a focused set of Git commands into structured tool operations.
// How: It validates command arguments, invokes ProcessRunner with bounded capture,
// and returns normalized results without embedding shell composition.
// Why: Version-control integration remains replaceable and separately auditable.

import Foundation

/// Git tool pack: status, diff, log, add, commit.
public struct GitToolPack: ToolPackHandling {
    private let runner = ProcessRunner()

    public init() {}

    public var toolNames: [String] {
        ["git_status", "git_diff", "git_log", "git_add", "git_commit"]
    }

    public func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult? {
        guard toolNames.contains(name) else { return nil }
        let cwd = ToolArgHelpers.string(arguments, "cwd") ?? FileManager.default.currentDirectoryPath
        var gitArgs: [String] = []
        switch name {
        case "git_status":
            gitArgs = ["status", "--porcelain=v1", "-b"]
        case "git_diff":
            gitArgs = ["diff"]
            if ToolArgHelpers.bool(arguments, "staged") == true { gitArgs.append("--cached") }
        case "git_log":
            let n = ToolArgHelpers.int(arguments, "limit") ?? 20
            gitArgs = ["log", "-n", "\(n)", "--oneline"]
        case "git_add":
            if let path = ToolArgHelpers.string(arguments, "path") { gitArgs = ["add", path] }
            else { gitArgs = ["add", "-A"] }
        case "git_commit":
            let msg = ToolArgHelpers.string(arguments, "message") ?? "chore: forge-conductor commit"
            gitArgs = ["commit", "-m", msg]
        default:
            return .failure(code: "unknown_git", message: name)
        }
        let result = try runner.run(executable: "git", arguments: gitArgs, currentDirectory: cwd, timeoutSec: 30)
        let ok = result.exitCode == 0
        return ToolResult(
            ok: ok,
            payload: [
                "ok": ok,
                "exit_code": result.exitCode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "cwd": cwd,
            ],
            isError: !ok
        )
    }
}

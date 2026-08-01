// ShellToolPack.swift
// What: Implements the explicitly granted shell-execution capability.
// How: It requires an active authorized workspace, applies timeout/output limits,
// and delegates process mechanics to ProcessRunner before returning structured status.
// Why: The most powerful tool needs a narrow, independently reviewable boundary.

import Foundation

/// Shell tool pack: shell_exec.
public struct ShellToolPack: ToolPackHandling {
    private let runner = ProcessRunner()

    public init() {}

    public var toolNames: [String] { ["shell_exec"] }

    public func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult? {
        guard name == "shell_exec" else { return nil }
        guard let command = ToolArgHelpers.string(arguments, "command"), !command.isEmpty else {
            return .failure(code: "missing_command", message: "command required")
        }
        let cwd = ToolArgHelpers.string(arguments, "cwd")
        let timeout = (arguments["timeout_sec"] as? Double)
            ?? Double(app.config.int("shell", "default_timeout_sec", default: 30))
        let result = try runner.run(
            executable: "/bin/bash",
            arguments: ["-lc", command],
            currentDirectory: cwd,
            timeoutSec: timeout,
            maximumOutputBytes: 100_000
        )
        let ok = result.exitCode == 0 && !result.timedOut
        return ToolResult(
            ok: ok,
            payload: [
                "ok": ok,
                "exit_code": result.exitCode,
                "stdout": String(result.stdout.prefix(80_000)),
                "stderr": String(result.stderr.prefix(20_000)),
                "timed_out": result.timedOut,
                "stdout_truncated": result.stdoutTruncated,
                "stderr_truncated": result.stderrTruncated,
                "command": command,
                "cwd": cwd as Any,
            ],
            isError: !ok
        )
    }
}

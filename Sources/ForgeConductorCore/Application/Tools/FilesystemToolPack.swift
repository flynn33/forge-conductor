// FilesystemToolPack.swift
// What: Implements the bounded file-management tool module.
// How: It performs read, write, edit, list, glob, move, directory, and delete
// operations only after ToolAuthorizationService has approved canonical paths.
// Why: Filesystem connector code is isolated from routing and domain services.

import Foundation

/// Filesystem tool pack: read/write/edit/list/glob/mkdir/delete/move.
public struct FilesystemToolPack: ToolPackHandling {
    private static let maximumTextFileBytes = 2 * 1024 * 1024
    public init() {}

    public var toolNames: [String] {
        ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "fs_delete", "fs_move"]
    }

    public func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult? {
        switch name {
        case "fs_read": return try fsRead(arguments)
        case "fs_write": return try fsWrite(arguments)
        case "fs_edit": return try fsEdit(arguments)
        case "fs_list": return try fsList(arguments)
        case "fs_glob": return try fsGlob(arguments, runner: ProcessRunner())
        case "fs_mkdir": return try fsMkdir(arguments)
        case "fs_delete": return try fsDelete(arguments)
        case "fs_move": return try fsMove(arguments)
        default: return nil
        }
    }

    private func fsRead(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maximumTextFileBytes else {
            return .failure(
                code: "file_too_large",
                message: "Text reads are limited to \(Self.maximumTextFileBytes) bytes"
            )
        }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(code: "not_found", message: "Not a readable file: \(url.path)")
        }
        return .success(["path": url.path, "content": text, "size": data.count])
    }

    private func fsWrite(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let content = ToolArgHelpers.string(args, "content") else {
            return .failure(code: "missing_args", message: "path and content required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: url, options: .atomic)
        return .success(["path": url.path, "bytes_written": data.count])
    }

    private func fsEdit(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let old = ToolArgHelpers.string(args, "old"),
              let new = ToolArgHelpers.string(args, "new") else {
            return .failure(code: "missing_args", message: "path, old, new required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(code: "not_found", message: url.path)
        }
        let count = text.components(separatedBy: old).count - 1
        guard count > 0 else {
            return .failure(code: "no_match", message: "old string not found")
        }
        text = text.replacingOccurrences(of: old, with: new)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return .success(["path": url.path, "replacements": count])
    }

    private func fsList(_ args: [String: Any]) throws -> ToolResult {
        let path = ToolArgHelpers.string(args, "path") ?? FileManager.default.currentDirectoryPath
        let url = ToolArgHelpers.resolvePath(path)
        let items = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return .success(["path": url.path, "entries": items.sorted()])
    }

    private func fsGlob(_ args: [String: Any], runner: ProcessRunner) throws -> ToolResult {
        let pattern = ToolArgHelpers.string(args, "pattern") ?? "*"
        let root = ToolArgHelpers.string(args, "path") ?? FileManager.default.currentDirectoryPath
        let rootURL = ToolArgHelpers.resolvePath(root)
        let result = try runner.run(
            executable: "/usr/bin/find",
            arguments: [rootURL.path, "-name", pattern],
            timeoutSec: 15
        )
        let files = result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .success(["path": rootURL.path, "pattern": pattern, "matches": Array(files.prefix(500))])
    }

    private func fsMkdir(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .success(["path": url.path, "ok": true])
    }

    private func fsDelete(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path") else {
            return .failure(code: "missing_path", message: "path required")
        }
        let url = ToolArgHelpers.resolvePath(path)
        try FileManager.default.removeItem(at: url)
        return .success(["path": url.path, "deleted": true])
    }

    private func fsMove(_ args: [String: Any]) throws -> ToolResult {
        guard let src = ToolArgHelpers.string(args, "path")
                ?? ToolArgHelpers.string(args, "src")
                ?? ToolArgHelpers.string(args, "source"),
              let dest = ToolArgHelpers.string(args, "dest")
                ?? ToolArgHelpers.string(args, "destination") else {
            return .failure(code: "missing_args", message: "path/src and dest required")
        }
        let s = ToolArgHelpers.resolvePath(src)
        let d = ToolArgHelpers.resolvePath(dest)
        try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: s, to: d)
        return .success(["src": s.path, "dest": d.path])
    }
}

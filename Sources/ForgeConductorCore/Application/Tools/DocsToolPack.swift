// DocsToolPack.swift
// What: Provides native PDF-generation tools to external MCP clients.
// How: It translates validated tool arguments into PDFWriter operations and returns
// bounded, structured success or error payloads.
// Why: Document capability is an optional module rather than a responsibility of Core routing.

import Foundation

/// Documentation tools: PDF write / PDF from file.
public struct DocsToolPack: ToolPackHandling {
    public init() {}

    public var toolNames: [String] { ["pdf_write", "pdf_from_file"] }

    public func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult? {
        switch name {
        case "pdf_write":
            return try pdfWrite(arguments)
        case "pdf_from_file":
            return try pdfFromFile(arguments)
        default:
            return nil
        }
    }

    private func pdfWrite(_ args: [String: Any]) throws -> ToolResult {
        guard let path = ToolArgHelpers.string(args, "path"),
              let content = ToolArgHelpers.string(args, "content") else {
            return .failure(code: "missing_args", message: "path and content required")
        }
        var url = ToolArgHelpers.resolvePath(path)
        if url.pathExtension.lowercased() != "pdf" {
            url = url.appendingPathExtension("pdf")
        }
        let title = ToolArgHelpers.string(args, "title") ?? url.deletingPathExtension().lastPathComponent
        let meta = try PDFWriter.write(path: url, content: content, title: title)
        return .success(meta)
    }

    private func pdfFromFile(_ args: [String: Any]) throws -> ToolResult {
        guard let source = ToolArgHelpers.string(args, "source_path") else {
            return .failure(code: "missing_source", message: "source_path required")
        }
        let src = ToolArgHelpers.resolvePath(source)
        guard let content = try? String(contentsOf: src, encoding: .utf8) else {
            return .failure(code: "not_found", message: src.path)
        }
        let dest: URL
        if let d = ToolArgHelpers.string(args, "dest_path"), !d.isEmpty {
            dest = ToolArgHelpers.resolvePath(d)
        } else {
            dest = src.deletingPathExtension().appendingPathExtension("pdf")
        }
        let title = ToolArgHelpers.string(args, "title") ?? src.deletingPathExtension().lastPathComponent
        var meta = try PDFWriter.write(path: dest, content: content, title: title)
        meta["source_path"] = src.path
        return .success(meta)
    }
}

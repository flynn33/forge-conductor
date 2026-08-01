// ToolArgHelpers.swift
// What: Defines common argument decoding and the tool-pack extension contract.
// How: Static helpers provide consistent required/optional coercion, while
// ToolPackHandling lets the router discover names and invoke a module uniformly.
// Why: Shared validation prevents subtly different behavior across connector modules.

import Foundation

/// Shared argument parsing for tool packs (wire JSON → Swift).
public enum ToolArgHelpers {
    public static func string(_ args: [String: Any], _ key: String) -> String? {
        if let s = args[key] as? String { return s }
        if let n = args[key] as? NSNumber { return n.stringValue }
        return nil
    }

    public static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(exactly: d) }
        if let s = args[key] as? String { return Int(s) }
        if let n = args[key] as? NSNumber { return Int(exactly: n.doubleValue) }
        return nil
    }

    public static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        if let b = args[key] as? Bool { return b }
        return nil
    }

    public static func resolvePath(_ raw: String) -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

public protocol ToolPackHandling: Sendable {
    /// Tool names this pack owns.
    var toolNames: [String] { get }
    func handle(name: String, arguments: [String: Any], clientID: ClientID, app: ForgeApp) throws -> ToolResult?
}

// ConfigStore.swift
// What: Persists AppConfig and exposes synchronized typed configuration access.
// How: A lock guards the in-memory model while atomic JSON writes, reload, and patch
// operations validate changes before replacing the durable file.
// Why: Readers need one consistent configuration owner across concurrent services.

import Foundation

/// Persistence for `AppConfig`. Domain consumers use `model`; dict update remains for HTTP edge patches.
public final class ConfigStore: ConfigurationProviding, @unchecked Sendable {
    private var _model: AppConfig
    private let paths: AppPaths
    private let lock = NSLock()

    /// Thread-safe snapshot of the typed configuration.
    public var model: AppConfig {
        lock.lock(); defer { lock.unlock() }
        return _model
    }

    /// Legacy dictionary view (edge / deep inspection). Prefer `model`.
    public var values: [String: Any] {
        model.asDictionary()
    }

    public init(paths: AppPaths) {
        self.paths = paths
        self._model = .default
        reload()
    }

    public static var defaults: [String: Any] { AppConfig.default.asDictionary() }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        var merged = AppConfig.default.asDictionary()
        if let data = try? Data(contentsOf: paths.configJSON),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged = deepMerge(merged, obj)
        }
        _model = AppConfig.fromDictionary(merged)
    }

    /// Persist full config atomically.
    public func save() throws {
        let dict = model.asDictionary()
        try paths.ensureLayout()
        let data = try JSONSupport.data(from: dict)
        try data.write(to: paths.configJSON, options: .atomic)
    }

    /// Deep-merge dictionary patch (HTTP / legacy) into live model.
    @discardableResult
    public func update(_ patch: [String: Any], save: Bool = true) throws -> [String: Any] {
        lock.lock()
        _model = _model.applying(patch: patch)
        let out = _model.asDictionary()
        lock.unlock()
        if save { try self.save() }
        return out
    }

    /// Typed settings patch path.
    @discardableResult
    public func update(_ patch: ManagerSettingsPatch, save: Bool = true) throws -> AppConfig {
        lock.lock()
        _model = _model.applying(settings: patch)
        let out = _model
        lock.unlock()
        if save { try self.save() }
        return out
    }

    /// Replace entire typed model.
    public func replace(_ config: AppConfig, save: Bool = true) throws {
        lock.lock()
        _model = config
        lock.unlock()
        if save { try self.save() }
    }

    public func int(_ keys: String..., default def: Int) -> Int {
        let dict = model.asDictionary()
        if let i = nested(keys, in: dict) as? Int { return i }
        if let d = nested(keys, in: dict) as? Double { return Int(d) }
        return def
    }

    public func string(_ keys: String..., default def: String) -> String {
        nested(keys, in: model.asDictionary()) as? String ?? def
    }

    public func bool(_ keys: String..., default def: Bool) -> Bool {
        nested(keys, in: model.asDictionary()) as? Bool ?? def
    }

    public func dictionary(_ keys: String...) -> [String: Any] {
        nested(keys, in: model.asDictionary()) as? [String: Any] ?? [:]
    }

    public var dashboard: AppConfig.DashboardConfig { model.dashboard }
    public var managerSection: AppConfig.ManagerConfigSection { model.manager }

    private func nested(_ path: [String], in values: [String: Any]) -> Any? {
        var cur: Any? = values
        for p in path {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[p]
        }
        return cur
    }

    private func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let bv = base[k] as? [String: Any], let ov = v as? [String: Any] {
                out[k] = deepMerge(bv, ov)
            } else {
                out[k] = v
            }
        }
        return out
    }
}

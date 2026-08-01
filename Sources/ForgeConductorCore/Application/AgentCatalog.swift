// AgentCatalog.swift
// What: Loads built-in and user-supplied agent playbooks into a typed catalog.
// How: It resolves resource/disk sources, parses Markdown front matter, validates
// specifications, and deterministically lets custom definitions override built-ins.
// Why: New agent modules can be added as data without changing framework control flow.

import Foundation

/// Loads agent playbooks from bundled Resources/Agents and ~/.forge-conductor/agents.
public final class AgentCatalog: AgentCatalogProviding, @unchecked Sendable {
    private let paths: AppPaths
    private var cache: [String: AgentSpec] = [:]
    private let lock = NSLock()

    public init(paths: AppPaths) {
        self.paths = paths
        reload()
    }

    public func reload() {
        lock.lock()
        defer { lock.unlock() }
        var map: [String: AgentSpec] = [:]
        // Built-ins from bundle (multiple layout variants for SPM vs Xcode resource copy)
        let bundleDirs = ["Agents", "Resources/Agents", nil as String?]
        for sub in bundleDirs {
            let urls: [URL]
            if let sub {
                urls = ResourceBundle.bundle.urls(forResourcesWithExtension: "md", subdirectory: sub) ?? []
            } else {
                urls = ResourceBundle.bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
            }
            for url in urls {
                // Prefer only agent playbooks (frontmatter with id) — ignore unrelated .md
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      text.hasPrefix("---"),
                      let spec = try? AgentMarkdownParser.parse(text: text, source: "builtin") else { continue }
                map[spec.id] = spec
            }
        }
        // Also try on-disk path next to sources when resources not yet in bundle
        let diskAgents = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Application
            .deletingLastPathComponent() // ForgeConductorCore
            .appendingPathComponent("Resources/Agents", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: diskAgents, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "md" {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let spec = try? AgentMarkdownParser.parse(text: text, source: "builtin") {
                    map[spec.id] = spec
                }
            }
        }
        // Compile-time defaults fill any missing ids
        let fallback = bundledAgentsFallback()
        for spec in fallback where map[spec.id] == nil { map[spec.id] = spec }

        // Custom home agents fully replace same id
        let homeAgents = paths.agentsDir
        if let files = try? FileManager.default.contentsOfDirectory(at: homeAgents, includingPropertiesForKeys: nil) {
            for url in files where url.pathExtension == "md" {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let spec = try? AgentMarkdownParser.parse(text: text, source: "custom") {
                    map[spec.id] = spec
                }
            }
        }
        // Ensure minimal defaults always exist
        for spec in AgentCatalog.builtinDefaults() {
            if map[spec.id] == nil { map[spec.id] = spec }
        }
        cache = map
    }

    public func all() -> [AgentSpec] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.sorted { $0.id < $1.id }
    }

    public func get(_ id: String) -> AgentSpec? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    public func recommend(task: String) -> AgentSpec {
        let t = task.lowercased()
        let rules: [(String, [String])] = [
            ("precommit-audit", ["commit", "precommit", "pull request", "pr ", "ok_to_commit"]),
            ("security", ["security", "auth", "secret", "injection"]),
            ("debug", ["debug", "crash", "traceback", "exception", "failing"]),
            ("test", ["test", "pytest", "coverage"]),
            ("docs", ["docs", "readme", "pdf", "manual", "handbook", "runbook", "documentation"]),
            ("research", ["research", "web search", "http"]),
            ("review", ["review", "critique"]),
            ("plan", ["plan", "design", "architecture"]),
            ("explore", ["explore", "map", "codebase", "structure", "overview", "unfamiliar"]),
            ("implement", ["implement", "feature", "bugfix", "write code", "edit"]),
        ]
        for (id, keys) in rules {
            if keys.contains(where: { t.contains($0) }), let spec = get(id) {
                return spec
            }
        }
        return get("explore") ?? AgentCatalog.builtinDefaults()[0]
    }

    private func bundledAgentsFallback() -> [AgentSpec] {
        // Compile-time defaults if resources not yet copied
        AgentCatalog.builtinDefaults()
    }

    public static func builtinDefaults() -> [AgentSpec] {
        [
            AgentSpec(
                id: "explore",
                displayName: "Explore",
                description: "Map a codebase and report structure, entry points, build/test, risks, and next specialist.",
                tools: ["fs_list", "fs_read", "fs_glob", "search_text", "git_status", "git_log", "git_diff", "shell_exec"],
                toolsForbidden: ["fs_write", "fs_edit", "fs_delete", "fs_move", "git_commit", "git_push", "git_add"],
                whenToUse: ["Unfamiliar repository", "Need structure map before plan/implement"],
                firstMoves: ["fs_list root", "locate Package.swift/xcodeproj", "git_status", "read entry points", "agent_run_complete"],
                doneDefinition: ["Layout + entry points with real paths", "build_test_run identified", "agent_run_complete"],
                outputSchema: ["layout", "entry_points", "build_test_run", "dependencies_config", "risks", "next_agent"],
                handoff: ["plan", "implement", "debug"],
                qualityBar: ["Paths verified via tools", "Never invent file names", "Always agent_run_complete"],
                body: """
                You are Explore (read-only). Map the codebase with tool-verified paths.
                Never mutate files. Always call agent_run_complete with layout, entry_points,
                build_test_run, dependencies_config, risks, next_agent.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "implement",
                displayName: "Implement",
                description: "Implement features and bugfixes with focused, verified code changes.",
                tools: ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text", "shell_exec", "git_status", "git_diff", "git_add", "git_commit"],
                toolsForbidden: ["git_push"],
                whenToUse: ["Feature or bugfix with known scope"],
                firstMoves: ["fs_read surrounding code", "minimal edit", "run tests when safe", "agent_run_complete"],
                doneDefinition: ["Change on disk", "how_to_verify concrete", "agent_run_complete"],
                outputSchema: ["what_changed", "files_touched", "how_to_verify", "residual_risks"],
                handoff: ["test", "review", "precommit-audit"],
                qualityBar: ["Smallest correct change", "Match modularity", "Always agent_run_complete"],
                body: """
                You are Implement. Read before write. Prefer fs_edit for surgical patches.
                Do not git_push. Always agent_run_complete with what_changed, files_touched,
                how_to_verify, residual_risks.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "docs",
                displayName: "Docs",
                description: "Write Markdown documentation and export PDF manuals via native tools.",
                tools: ["fs_read", "fs_write", "fs_edit", "fs_list", "fs_glob", "fs_mkdir", "search_text", "shell_exec", "pdf_write", "pdf_from_file", "git_status", "git_diff", "git_log"],
                toolsForbidden: ["git_push", "git_commit"],
                whenToUse: ["README", "PDF manual", "runbook", "API docs"],
                firstMoves: ["fs_glob docs/README", "fs_read sources", "fs_write markdown", "pdf_from_file if needed", "agent_run_complete"],
                doneDefinition: ["Artifacts on disk", "files_touched filled", "agent_run_complete"],
                outputSchema: ["files_touched", "summary", "formats", "how_to_open"],
                handoff: ["review"],
                qualityBar: ["No aspirational docs", "Prefer pdf_write over inventing pandoc", "Always agent_run_complete"],
                body: """
                You are Docs. Write accurate documentation with tools.
                For PDF use pdf_write / pdf_from_file (no pandoc). Always fill files_touched
                and call agent_run_complete. Never claim PDF done without a file on disk.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "debug",
                displayName: "Debug",
                description: "Diagnose failures from logs, stack traces, and failing tests with evidence.",
                tools: ["fs_read", "fs_list", "fs_glob", "search_text", "shell_exec", "git_status", "git_diff", "git_log"],
                toolsForbidden: ["git_push"],
                whenToUse: ["Failing tests", "crashes", "unexpected behavior"],
                firstMoves: ["Capture exact error", "trace path with fs_read/search_text", "agent_run_complete"],
                doneDefinition: ["Root cause with evidence", "agent_run_complete"],
                outputSchema: ["symptom", "repro", "root_cause", "fix", "verify"],
                handoff: ["test", "implement", "review"],
                qualityBar: ["Evidence before large rewrites", "Always agent_run_complete"],
                body: """
                You are Debug. Find root causes with evidence (log lines, exit codes, paths).
                Fill symptom, repro, root_cause, fix, verify. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "precommit-audit",
                displayName: "Pre-commit Audit",
                description: "Mandatory audit before git commit or PR — gate on OK_TO_COMMIT.",
                tools: ["git_status", "git_diff", "git_log", "fs_read", "search_text", "shell_exec"],
                toolsForbidden: ["git_commit", "git_push"],
                whenToUse: ["Before every commit", "Before PR"],
                firstMoves: ["git_status", "git_diff staged+unstaged", "scan secrets", "agent_run_complete"],
                doneDefinition: ["OK_TO_COMMIT yes/no", "blockers listed", "agent_run_complete"],
                outputSchema: ["diff_summary", "risks", "OK_TO_COMMIT", "blockers"],
                handoff: ["implement"],
                qualityBar: ["Block on secrets", "Always agent_run_complete"],
                body: """
                You are Pre-commit Audit. Never commit. Always agent_run_complete with
                diff_summary, risks, OK_TO_COMMIT (yes|no), blockers.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "plan",
                displayName: "Plan",
                description: "Design multi-step implementation plans with files, risks, and verification.",
                tools: ["fs_read", "fs_list", "fs_glob", "search_text", "git_status", "git_log", "shell_exec"],
                toolsForbidden: ["fs_write", "fs_edit", "fs_delete", "git_commit", "git_push", "git_add"],
                whenToUse: ["Architecture or multi-file feature design"],
                firstMoves: ["Map modules", "read key interfaces", "agent_run_complete"],
                doneDefinition: ["Ordered steps + files + verify", "agent_run_complete"],
                outputSchema: ["goal", "steps", "files", "risks", "verify", "next_agent"],
                handoff: ["implement", "explore"],
                qualityBar: ["Actionable ordered steps", "Always agent_run_complete"],
                body: """
                You are Plan (no production code writes). Produce goal, steps, files, risks,
                verify, next_agent. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "review",
                displayName: "Review",
                description: "Review diffs for correctness, security, tests, and maintainability.",
                tools: ["git_status", "git_diff", "git_log", "fs_read", "search_text", "shell_exec"],
                toolsForbidden: ["git_commit", "git_push", "fs_write", "fs_edit", "fs_delete"],
                whenToUse: ["After implementation before merge"],
                firstMoves: ["git_diff", "fs_read high-risk hunks", "agent_run_complete"],
                doneDefinition: ["Verdict approve|request_changes", "agent_run_complete"],
                outputSchema: ["summary", "blockers", "nits", "test_gaps", "security", "verdict"],
                handoff: ["implement", "test", "precommit-audit"],
                qualityBar: ["Path-specific blockers", "Always agent_run_complete"],
                body: """
                You are Review (read-only). Separate blockers from nits. Cover security and
                test_gaps. Verdict: approve or request_changes. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "test",
                displayName: "Test",
                description: "Discover, run, and report verification; identify coverage gaps.",
                tools: ["shell_exec", "fs_read", "fs_list", "fs_glob", "search_text", "git_status"],
                toolsForbidden: ["git_push", "git_commit"],
                whenToUse: ["Need evidence tests pass/fail", "Improve verification"],
                firstMoves: ["Discover test runner", "run targeted suite", "agent_run_complete"],
                doneDefinition: ["Commands and results recorded", "agent_run_complete"],
                outputSchema: ["commands", "results", "gaps", "follow_ups"],
                handoff: ["implement", "debug"],
                qualityBar: ["Never invent pass/fail", "Always agent_run_complete"],
                body: """
                You are Test. Run real commands via shell_exec; do not claim success without output.
                Prefer xcodebuild test / swift test / npm test / pytest. Always agent_run_complete
                with commands, results, gaps, follow_ups.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "security",
                displayName: "Security",
                description: "Threat-model changes; scan for secrets, injection, and unsafe patterns.",
                tools: ["git_status", "git_diff", "fs_read", "fs_glob", "search_text", "shell_exec"],
                toolsForbidden: ["git_commit", "git_push", "fs_write", "fs_edit", "fs_delete"],
                whenToUse: ["Auth/secrets/network/shell changes", "Pre-release security pass"],
                firstMoves: ["git_diff for attack surface", "search_text for secrets/injection", "agent_run_complete"],
                doneDefinition: ["Findings ranked", "Remediations listed", "agent_run_complete"],
                outputSchema: ["scope", "findings", "severity_summary", "remediations", "residual_risk"],
                handoff: ["implement", "precommit-audit", "review"],
                qualityBar: ["Concrete exploit paths", "Never print live secrets", "Always agent_run_complete"],
                body: """
                You are Security. Read-only analysis. Rank findings critical/high/medium/low/info.
                Check secrets, injection, path traversal, SSRF, authz gaps. Always agent_run_complete.
                """,
                source: "builtin"
            ),
            AgentSpec(
                id: "research",
                displayName: "Research",
                description: "Gather facts from the local codebase with path citations.",
                tools: ["fs_read", "fs_list", "fs_glob", "search_text", "git_log", "git_status", "shell_exec"],
                toolsForbidden: ["fs_write", "fs_edit", "fs_delete", "git_commit", "git_push"],
                whenToUse: ["Factual question about how the system works"],
                firstMoves: ["search_text / fs_glob", "fs_read sources", "agent_run_complete"],
                doneDefinition: ["Answer with citations", "Uncertainties listed", "agent_run_complete"],
                outputSchema: ["question", "findings", "citations", "uncertainties", "next_agent"],
                handoff: ["plan", "implement", "docs"],
                qualityBar: ["Every claim needs path evidence", "Always agent_run_complete"],
                body: """
                You are Research. Prefer repository evidence over general knowledge.
                Cite paths. Separate fact from inference. Always agent_run_complete.
                """,
                source: "builtin"
            ),
        ]
    }
}

// MARK: - Markdown frontmatter parser

public enum AgentMarkdownParser {
    public static func parse(text: String, source: String) throws -> AgentSpec {
        guard text.hasPrefix("---") else {
            throw NSError(domain: "AgentMarkdown", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Agent markdown must start with YAML frontmatter",
            ])
        }
        let parts = text.components(separatedBy: "---")
        // ["", frontmatter, body...]
        guard parts.count >= 3 else {
            throw NSError(domain: "AgentMarkdown", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid frontmatter fences",
            ])
        }
        let fm = parts[1]
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = SimpleYAML.map(from: fm)
        guard let id = meta["id"], !id.isEmpty else {
            throw NSError(domain: "AgentMarkdown", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "frontmatter requires id",
            ])
        }
        return AgentSpec(
            id: id,
            displayName: meta["display_name"] ?? id,
            description: meta["description"] ?? "",
            tools: list(meta["tools"]),
            toolsForbidden: list(meta["tools_forbidden"]),
            whenToUse: list(meta["when_to_use"]),
            firstMoves: list(meta["first_moves"]),
            doneDefinition: list(meta["done_definition"]),
            outputSchema: list(meta["output_schema"]),
            handoff: list(meta["handoff"]),
            qualityBar: list(meta["quality_bar"]),
            body: body,
            source: source
        )
    }

    private static func list(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        // bracket list or comma list
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("[") && s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }.filter { !$0.isEmpty }
    }
}

/// Tiny subset YAML: key: value lines only (no nested structures beyond lists as strings).
enum SimpleYAML {
    static func map(from text: String) -> [String: String] {
        var out: [String: String] = [:]
        var currentKey: String?
        var currentVal = ""
        func flush() {
            if let k = currentKey {
                out[k] = currentVal.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentKey = nil
            currentVal = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            if let r = line.range(of: ":"), !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") {
                flush()
                let k = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var v = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix(">") || v.hasPrefix("|") { v = "" }
                if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                    v = String(v.dropFirst().dropLast())
                }
                currentKey = k
                currentVal = v
            } else if currentKey != nil {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("- ") {
                    let item = String(t.dropFirst(2))
                    if currentVal.isEmpty { currentVal = item }
                    else if currentVal.hasPrefix("[") {
                        // already bracket form
                        currentVal = String(currentVal.dropLast()) + ", " + item + "]"
                    } else {
                        currentVal += ", " + item
                    }
                } else if !t.isEmpty {
                    currentVal += " " + t
                }
            }
        }
        flush()
        return out
    }
}

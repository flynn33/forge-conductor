"""Load built-in and custom host-driven agent markdown specs."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from importlib import resources
from pathlib import Path
from typing import Any

import yaml


def _as_str_list(raw: Any) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, str):
        return [t.strip() for t in raw.split(",") if t.strip()]
    if isinstance(raw, list):
        return [str(t).strip() for t in raw if str(t).strip()]
    return []


# Built-in playbook defaults (frontmatter can override any field).
# Large-context hosts: prefer full specialist packs over token thrift.
DEFAULT_PLAYBOOKS: dict[str, dict[str, Any]] = {
    "explore": {
        "when_to_use": [
            "Unfamiliar or large codebase",
            "Need map of structure, entry points, build/test",
            "Before planning a multi-file change",
            "Audit / overview of a repo",
        ],
        "when_not_to_use": [
            "Single-file typo or known one-liner fix",
            "User asked a pure conceptual question with no repo work",
        ],
        "first_moves": [
            "Read super_context.active_project + handoff first",
            "fs_list or fs_glob at repo root",
            "search_files for package manifests (package.json, pyproject.toml, *.sln)",
            "git_status + git_log(limit small) for recent activity",
            "fs_read README / main entry modules",
        ],
        "done_definition": [
            "Top-level layout described",
            "Entry points identified",
            "Build/test/run commands known or noted as missing",
            "Risks and recommended next agent listed",
        ],
        "output_schema": [
            "layout",
            "entry_points",
            "build_test_run",
            "dependencies_config",
            "risks",
            "next_agent",
        ],
        "tools_forbidden": [
            "fs_write",
            "fs_edit",
            "fs_delete",
            "fs_move",
            "git_commit",
            "git_push",
            "shell_exec",
        ],
        "tools_forbidden_note": "Explore is read-only; use shell_exec only if needed for --help discovery with care",
        "handoff": ["plan", "implement", "review"],
        "quality_bar": [
            "Prefer structured findings over long narrative",
            "Cite concrete paths",
            "Do not invent files that were not observed",
        ],
    },
    "plan": {
        "when_to_use": [
            "Multi-step feature or refactor",
            "Need design before coding",
            "Trade-offs or sequencing unclear",
            "Structure a roadmap or implementation sequence (content only)",
        ],
        "when_not_to_use": [
            "Trivial fix with obvious single edit",
            "User only wants a markdown file written — use docs after plan or docs alone",
        ],
        "first_moves": [
            "Read super_context.active_project + handoff + related_memory first",
            "agent_context or reuse explore findings",
            "fs_read key modules involved",
            "search_text for existing patterns to extend",
        ],
        "done_definition": [
            "Goal restated",
            "Steps ordered",
            "Files likely touched",
            "Risks and verification plan",
            "next_agent set (docs for markdown deliverables, implement for code)",
        ],
        "output_schema": [
            "goal",
            "steps",
            "files",
            "risks",
            "verify",
            "next_agent",
        ],
        "tools_forbidden": [
            "fs_write",
            "fs_edit",
            "fs_delete",
            "fs_move",
            "git_commit",
            "git_push",
            "gh_pr_create",
        ],
        "handoff": ["docs", "implement", "review"],
        "quality_bar": [
            "Steps must be actionable with tools",
            "Prefer smallest viable plan",
            "NEVER write files — agent_run_complete then hand off (docs for ROADMAP/README, implement for code)",
        ],
    },
    "implement": {
        "when_to_use": [
            "Code changes required",
            "Feature or bugfix after plan/explore",
        ],
        "when_not_to_use": [
            "User only wants analysis or review",
            "Markdown-only deliverable — use docs",
        ],
        "first_moves": [
            "Read super_context (plan steps, prior_runs, related_memory)",
            "fs_read surrounding code before edit",
            "search_text for call sites / patterns",
            "fs_edit or fs_write minimal diffs",
            "shell_exec or python_* / tests to verify",
        ],
        "done_definition": [
            "Requested behavior implemented",
            "Diff is focused",
            "Verification attempted or explained",
        ],
        "output_schema": [
            "what_changed",
            "files_touched",
            "how_to_verify",
            "residual_risks",
        ],
        "tools_forbidden": [],
        "handoff": ["test", "review", "precommit-audit"],
        "quality_bar": [
            "Read before write",
            "Match project style",
            "No drive-by refactors",
        ],
    },
    "review": {
        "when_to_use": [
            "After substantive implementation",
            "Before commit/PR on risky changes",
        ],
        "when_not_to_use": ["No code changes to review"],
        "first_moves": [
            "git_status + git_diff",
            "fs_read changed files",
            "search_text for related tests",
        ],
        "done_definition": [
            "Correctness, tests, security, rollback considered",
            "Blocking vs non-blocking issues listed",
        ],
        "output_schema": [
            "summary",
            "blockers",
            "nits",
            "test_gaps",
            "security",
            "verdict",
        ],
        "tools_forbidden": ["git_commit", "git_push", "fs_write", "fs_edit"],
        "handoff": ["implement", "test", "precommit-audit"],
        "quality_bar": ["Be specific with file:line or path", "Separate blockers from nits"],
    },
    "debug": {
        "when_to_use": ["Failing tests, crashes, unexpected behavior"],
        "when_not_to_use": ["Greenfield feature with no failure"],
        "first_moves": [
            "Reproduce with shell_exec / python_exec",
            "fs_read stack-related files",
            "search_text for error strings",
        ],
        "done_definition": [
            "Root cause hypothesis with evidence",
            "Fix applied or clear next experiment",
        ],
        "output_schema": ["symptom", "repro", "root_cause", "fix", "verify"],
        "tools_forbidden": [],
        "handoff": ["test", "implement", "review"],
        "quality_bar": ["Evidence before large rewrites"],
    },
    "test": {
        "when_to_use": ["Need tests or to run verification suite"],
        "when_not_to_use": ["No code path to validate"],
        "first_moves": [
            "Discover test runner (pytest, npm test, etc.)",
            "Run targeted tests",
            "Add/adjust tests if missing",
        ],
        "done_definition": ["Tests run with reported result", "Gaps noted"],
        "output_schema": ["commands", "results", "gaps", "follow_ups"],
        "tools_forbidden": ["git_push"],
        "handoff": ["implement", "review"],
        "quality_bar": ["Prefer targeted tests over full suite when slow"],
    },
    "research": {
        "when_to_use": ["Need external docs, APIs, or web facts"],
        "when_not_to_use": ["Answer is fully in the local repo"],
        "first_moves": ["web_search or http_fetch", "doc_ingest if multi-page"],
        "done_definition": ["Sources cited", "Local applicability stated"],
        "output_schema": ["findings", "sources", "local_application"],
        "tools_forbidden": ["git_commit", "git_push"],
        "handoff": ["plan", "implement", "docs"],
        "quality_bar": ["Prefer primary sources"],
    },
    "docs": {
        "when_to_use": [
            "README, API docs, runbooks need update",
            "Write ROADMAP.md / architecture notes / contributor guides",
            "Turn a plan report into on-disk markdown",
            "Any user-facing or developer markdown deliverable",
        ],
        "when_not_to_use": ["Code-only change with no docs impact"],
        "first_moves": [
            "Read super_context (plan report in prior_runs / related_memory)",
            "fs_read existing docs",
            "fs_write or fs_edit accurate updates",
        ],
        "done_definition": [
            "Target markdown file(s) written or updated",
            "Docs match actual behavior / agreed plan",
        ],
        "output_schema": ["files_touched", "summary", "audience"],
        "tools_forbidden": ["git_push"],
        "handoff": ["review", "precommit-audit"],
        "quality_bar": [
            "No aspirational docs for unimplemented features",
            "Cite real paths and commands from the repo",
        ],
    },
    "refactor": {
        "when_to_use": ["Structure improvement without behavior change"],
        "when_not_to_use": ["Feature work mixed with cleanup — split tasks"],
        "first_moves": [
            "Characterize current structure",
            "Small safe steps with verification",
        ],
        "done_definition": ["Behavior preserved", "Structure improved", "Verify ran"],
        "output_schema": ["intent", "steps", "files", "verify"],
        "tools_forbidden": [],
        "handoff": ["test", "review"],
        "quality_bar": ["Keep diffs reviewable"],
    },
    "security": {
        "when_to_use": ["Auth, secrets, injection, trust boundaries"],
        "when_not_to_use": ["Pure UI copy tweaks"],
        "first_moves": [
            "search_text for secrets/patterns",
            "fs_read auth and input paths",
        ],
        "done_definition": ["Threats listed", "Severity", "Remediation"],
        "output_schema": ["findings", "severity", "remediation"],
        "tools_forbidden": ["git_push"],
        "handoff": ["implement", "review"],
        "quality_bar": ["No speculative critical claims without evidence"],
    },
    "release": {
        "when_to_use": ["Versioning, changelog, release steps"],
        "when_not_to_use": ["Mid-feature development"],
        "first_moves": ["git_status", "git_log", "fs_read version files"],
        "done_definition": ["Release checklist complete or blocked with reason"],
        "output_schema": ["version", "changelog", "steps", "blockers"],
        "tools_forbidden": [],
        "handoff": ["precommit-audit"],
        "quality_bar": ["Never force-push release tags without user ask"],
    },
    "precommit-audit": {
        "when_to_use": ["Before every git commit or PR"],
        "when_not_to_use": [],
        "first_moves": [
            "git_status",
            "git_diff",
            "Structured OK_TO_COMMIT yes/no",
        ],
        "done_definition": ["OK_TO_COMMIT=yes or blockers listed"],
        "output_schema": ["diff_summary", "risks", "OK_TO_COMMIT", "blockers"],
        "tools_forbidden": ["git_commit", "git_push", "gh_pr_create"],
        "handoff": ["implement"],
        "quality_bar": ["Block on secrets, debug leftovers, broken tests if known"],
    },
}


@dataclass
class AgentSpec:
    """Parsed agent specification (frontmatter + markdown body + playbook)."""

    id: str
    display_name: str
    description: str
    tools: list[str] = field(default_factory=list)
    body: str = ""
    source: str = "builtin"  # "builtin" | "custom"
    when_to_use: list[str] = field(default_factory=list)
    when_not_to_use: list[str] = field(default_factory=list)
    first_moves: list[str] = field(default_factory=list)
    done_definition: list[str] = field(default_factory=list)
    output_schema: list[str] = field(default_factory=list)
    tools_forbidden: list[str] = field(default_factory=list)
    handoff: list[str] = field(default_factory=list)
    quality_bar: list[str] = field(default_factory=list)

    def playbook(self) -> dict[str, Any]:
        return {
            "when_to_use": list(self.when_to_use),
            "when_not_to_use": list(self.when_not_to_use),
            "first_moves": list(self.first_moves),
            "done_definition": list(self.done_definition),
            "output_schema": list(self.output_schema),
            "tools_primary": list(self.tools),
            "tools_forbidden": list(self.tools_forbidden),
            "handoff": list(self.handoff),
            "quality_bar": list(self.quality_bar),
        }

    def to_dict(self, *, include_body: bool = True) -> dict[str, Any]:
        data: dict[str, Any] = {
            "id": self.id,
            "display_name": self.display_name,
            "description": self.description,
            "tools": list(self.tools),
            "source": self.source,
            "playbook": self.playbook(),
        }
        if include_body:
            data["body"] = self.body
        return data

    def card(self) -> dict[str, Any]:
        """Compact listing card (bootstrap / list)."""
        return {
            "id": self.id,
            "display_name": self.display_name,
            "description": self.description,
            "source": self.source,
            "when_to_use": list(self.when_to_use)[:4],
            "handoff": list(self.handoff),
            "tools_primary": list(self.tools)[:12],
        }


_FRONTMATTER_RE = re.compile(
    r"\A---\s*\n(.*?)\n---\s*\n?(.*)\Z",
    re.DOTALL,
)


def _merge_playbook(agent_id: str, meta: dict[str, Any]) -> dict[str, list[str]]:
    base = dict(DEFAULT_PLAYBOOKS.get(agent_id, {}))
    fields = (
        "when_to_use",
        "when_not_to_use",
        "first_moves",
        "done_definition",
        "output_schema",
        "tools_forbidden",
        "handoff",
        "quality_bar",
    )
    out: dict[str, list[str]] = {}
    for f in fields:
        if f in meta and meta[f] is not None:
            out[f] = _as_str_list(meta[f])
        else:
            out[f] = _as_str_list(base.get(f))
    return out


def parse_agent_markdown(text: str, *, source: str = "builtin") -> AgentSpec:
    """Parse YAML frontmatter + markdown body into an AgentSpec."""
    match = _FRONTMATTER_RE.match(text)
    if not match:
        raise ValueError("Agent markdown must start with YAML frontmatter (--- ... ---)")

    raw_meta = match.group(1)
    body = match.group(2).strip("\n")
    meta = yaml.safe_load(raw_meta) or {}
    if not isinstance(meta, dict):
        raise ValueError("Agent frontmatter must be a YAML mapping")

    agent_id = str(meta.get("id") or "").strip()
    if not agent_id:
        raise ValueError("Agent frontmatter requires non-empty 'id'")

    display_name = str(meta.get("display_name") or agent_id).strip()
    description = str(meta.get("description") or "").strip()

    tools_raw = meta.get("tools") or []
    if isinstance(tools_raw, str):
        tools = [t.strip() for t in tools_raw.split(",") if t.strip()]
    elif isinstance(tools_raw, list):
        tools = [str(t).strip() for t in tools_raw if str(t).strip()]
    else:
        raise ValueError(f"Agent '{agent_id}' tools must be a list or comma-separated string")

    pb = _merge_playbook(agent_id, meta)

    return AgentSpec(
        id=agent_id,
        display_name=display_name,
        description=description,
        tools=tools,
        body=body,
        source=source,
        when_to_use=pb["when_to_use"],
        when_not_to_use=pb["when_not_to_use"],
        first_moves=pb["first_moves"],
        done_definition=pb["done_definition"],
        output_schema=pb["output_schema"],
        tools_forbidden=pb["tools_forbidden"],
        handoff=pb["handoff"],
        quality_bar=pb["quality_bar"],
    )


def _load_from_dir(directory: Path, *, source: str) -> dict[str, AgentSpec]:
    agents: dict[str, AgentSpec] = {}
    if not directory.is_dir():
        return agents
    for path in sorted(directory.glob("*.md")):
        text = path.read_text(encoding="utf-8")
        spec = parse_agent_markdown(text, source=source)
        agents[spec.id] = spec
    return agents


def _load_builtins() -> dict[str, AgentSpec]:
    agents: dict[str, AgentSpec] = {}
    package = resources.files("forge_conductor.agents")
    for entry in package.iterdir():
        name = getattr(entry, "name", "")
        if not name.endswith(".md"):
            continue
        text = entry.read_text(encoding="utf-8")
        spec = parse_agent_markdown(text, source="builtin")
        agents[spec.id] = spec
    return agents


def load_agents(home: Path | str | None = None) -> dict[str, AgentSpec]:
    """Load built-in agents, then fully replace any with custom `{home}/agents/*.md`.

    Same id fully replaces the built-in (no field merge).
    """
    if home is None:
        from forge_conductor.config import get_home

        home_path = get_home()
    else:
        home_path = Path(home)

    agents = _load_builtins()
    custom = _load_from_dir(home_path / "agents", source="custom")
    agents.update(custom)
    return agents


# Task routing for bootstrap / recommend
ROUTE_HINTS: list[dict[str, str]] = [
    {
        "match": "map / unknown repo / structure / codebase overview / audit repo",
        "agent_id": "explore",
        "call": "agent_run_start(agent_id='explore', goal=...)",
    },
    {
        "match": "ROADMAP.md / write documentation file / README update / runbook on disk",
        "agent_id": "docs",
        "call": "agent_run_start(agent_id='docs', goal=...) — chain: plan(optional)→docs",
    },
    {
        "match": "design / architecture / multi-step plan (no file write yet)",
        "agent_id": "plan",
        "call": "agent_run_start(agent_id='plan', goal=...) then docs|implement",
    },
    {
        "match": "implement feature / bugfix / write code",
        "agent_id": "implement",
        "call": "agent_run_start(agent_id='implement', goal=...)",
    },
    {
        "match": "code review / critique change",
        "agent_id": "review",
        "call": "agent_run_start(agent_id='review', goal=...)",
    },
    {
        "match": "failing test / crash / debug",
        "agent_id": "debug",
        "call": "agent_run_start(agent_id='debug', goal=...)",
    },
    {
        "match": "tests / verification suite",
        "agent_id": "test",
        "call": "agent_run_start(agent_id='test', goal=...)",
    },
    {
        "match": "security / auth / secrets",
        "agent_id": "security",
        "call": "agent_run_start(agent_id='security', goal=...)",
    },
    {
        "match": "docs / README / runbook / roadmap / markdown deliverable",
        "agent_id": "docs",
        "call": "agent_run_start(agent_id='docs', goal=...)",
    },
    {
        "match": "refactor structure",
        "agent_id": "refactor",
        "call": "agent_run_start(agent_id='refactor', goal=...)",
    },
    {
        "match": "release / version / changelog",
        "agent_id": "release",
        "call": "agent_run_start(agent_id='release', goal=...)",
    },
    {
        "match": "commit / PR / precommit",
        "agent_id": "precommit-audit",
        "call": "agent_run_start(agent_id='precommit-audit', goal=...) or precommit_gate",
    },
    {
        "match": "web / external API research",
        "agent_id": "research",
        "call": "agent_run_start(agent_id='research', goal=...)",
    },
]


def recommend_agent(task: str, home: Path | str | None = None) -> dict[str, Any]:
    """Keyword router: map free-text task to best agent_id."""
    t = (task or "").lower()
    agents = load_agents(home)
    # ordered keyword groups
    rules: list[tuple[list[str], str]] = [
        (["commit", "precommit", "pull request", " pr ", "ok_to_commit"], "precommit-audit"),
        (["security", "auth", "secret", "injection", "xss", "csrf"], "security"),
        (["debug", "crash", "traceback", "exception", "failing"], "debug"),
        (["test", "pytest", "coverage", "verify suite"], "test"),
        (["refactor", "cleanup structure"], "refactor"),
        (["release", "version bump"], "release"),
        # Doc deliverables BEFORE generic "plan" so ROADMAP.md goes to docs
        (
            [
                "roadmap",
                "readme",
                "documentation",
                "docs",
                "runbook",
                "write a md",
                ".md file",
                "markdown",
            ],
            "docs",
        ),
        (["research", "web search", "http fetch", "upstream api"], "research"),
        (["review", "critique", "look over the diff"], "review"),
        (["plan", "design", "architecture", "approach", "sequence tasks"], "plan"),
        (["explore", "map", "codebase", "structure", "overview", "unfamiliar", "audit repo"], "explore"),
        (["implement", "feature", "bugfix", "write code", "edit"], "implement"),
    ]
    for keys, aid in rules:
        if any(k.strip() in t for k in keys):
            if aid in agents or aid == "precommit-audit":
                spec = agents.get(aid)
                return {
                    "ok": True,
                    "agent_id": aid,
                    "reason": f"matched keywords for {aid}",
                    "call": f"agent_run_start(agent_id='{aid}', goal=...)",
                    "card": spec.card() if spec else {"id": aid},
                }
    # default implement for code-ish, else explore
    if any(k in t for k in ("fix", "add", "change", "update", "build")):
        aid = "implement" if "implement" in agents else next(iter(agents), "explore")
    else:
        aid = "explore" if "explore" in agents else next(iter(agents), "explore")
    spec = agents.get(aid)
    return {
        "ok": True,
        "agent_id": aid,
        "reason": "default routing",
        "call": f"agent_run_start(agent_id='{aid}', goal=...)",
        "card": spec.card() if spec else {"id": aid},
    }

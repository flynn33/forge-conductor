/**
 * Static catalog of Forge-Conductor MCP tools by pack.
 * Mirrors forge_conductor tool packs (build_mcp TOOL_NAMES).
 */
export const TOOL_PACKS = [
  {
    pack: "meta",
    tools: [
      "forge_status",
      "forge_audit_tail",
      "forge_config_get",
      "fail_forward",
      "host_hygiene",
    ],
  },
  {
    pack: "inventory",
    tools: [
      "session_bootstrap",
      "inventory_tools",
      "precommit_gate",
      "recommend_tools",
    ],
  },
  {
    pack: "filesystem",
    tools: [
      "fs_read",
      "fs_write",
      "fs_edit",
      "fs_list",
      "fs_glob",
      "fs_stat",
      "fs_mkdir",
      "fs_delete",
      "fs_move",
    ],
  },
  {
    pack: "shell",
    tools: ["shell_exec", "shell_which", "shell_env_get"],
  },
  {
    pack: "git",
    tools: [
      "git_status",
      "git_diff",
      "git_log",
      "git_branch",
      "git_show",
      "git_add",
      "git_commit",
      "git_stash",
    ],
  },
  {
    pack: "github",
    tools: [
      "gh_whoami",
      "git_fetch",
      "git_pull",
      "git_push",
      "git_checkout",
      "get_repo_file",
      "gh_pr_list",
      "gh_pr_view",
      "gh_pr_create",
    ],
  },
  {
    pack: "search",
    tools: ["search_text", "search_files"],
  },
  {
    pack: "python",
    tools: [
      "python_info",
      "python_exec",
      "python_eval",
      "python_run_file",
      "python_repl_reset",
    ],
  },
  {
    pack: "vsbuild",
    tools: ["vs_list", "vs_toolchain", "vs_msbuild", "vs_build_script"],
  },
  {
    pack: "browser",
    tools: [
      "browser_navigate",
      "browser_snapshot",
      "browser_click",
      "browser_type",
      "browser_screenshot",
      "browser_close",
    ],
  },
  {
    pack: "research",
    tools: ["web_search", "http_fetch", "doc_ingest", "doc_search"],
  },
  {
    pack: "memory",
    tools: [
      "memory_set",
      "memory_get",
      "memory_list",
      "memory_delete",
      "memory_search",
      "memory_stats",
      "memory_flush",
      "project_focus",
      "project_current",
      "handoff_save",
      "handoff_load",
      "ram_status",
    ],
  },
  {
    pack: "agents",
    tools: [
      "agent_list",
      "agent_recommend",
      "agent_get",
      "agent_context",
      "agent_run_start",
      "agent_run_status",
      "agent_run_complete",
      "agent_session_start",
      "agent_session_end",
      "agent_session_list",
      "agent_session_recover",
    ],
  },
  {
    pack: "coord",
    tools: [
      "coord_presence",
      "coord_lease_acquire",
      "coord_lease_release",
      "coord_job_create",
      "coord_job_claim",
      "coord_job_complete",
      "coord_status",
    ],
  },
];

export function allToolsFlat() {
  const out = [];
  for (const p of TOOL_PACKS) {
    for (const tool of p.tools) {
      out.push({ tool, pack: p.pack });
    }
  }
  return out;
}

export function packForTool(name) {
  for (const p of TOOL_PACKS) {
    if (p.tools.includes(name)) return p.pack;
  }
  return "other";
}

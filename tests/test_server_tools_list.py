from forge_conductor.server import build_mcp, TOOL_NAMES

REQUIRED_CORE = {
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
    "orchestration_status",
    "orchestration_flush",
    "orchestration_reload",
    "agent_chain_recommend",
    "forge_status",
    "forge_audit_tail",
    "forge_config_get",
}

REQUIRED_CODING = {
    "fs_read",
    "fs_write",
    "fs_edit",
    "fs_list",
    "fs_glob",
    "fs_stat",
    "fs_mkdir",
    "fs_delete",
    "fs_move",
    "shell_exec",
    "shell_which",
    "shell_env_get",
    "git_status",
    "git_diff",
    "git_log",
    "git_branch",
    "git_show",
    "git_add",
    "git_commit",
    "git_stash",
    "search_text",
    "search_files",
}

REQUIRED_COORD = {
    "coord_presence",
    "coord_lease_acquire",
    "coord_lease_release",
    "coord_job_create",
    "coord_job_claim",
    "coord_job_complete",
    "coord_status",
}

REQUIRED_AGENTS = {
    "agent_list",
    "agent_get",
    "agent_context",
    "agent_session_start",
    "agent_session_end",
    "agent_session_list",
}

REQUIRED_BROWSER = {
    "browser_navigate",
    "browser_snapshot",
    "browser_click",
    "browser_type",
    "browser_screenshot",
    "browser_close",
}

REQUIRED_RESEARCH = {
    "web_search",
    "http_fetch",
    "doc_ingest",
    "doc_search",
}


def test_tool_names_include_core_after_task5():
    build_mcp()  # ensure registration runs
    assert REQUIRED_CORE <= set(TOOL_NAMES)


def test_tool_names_include_coding_packs_task6():
    build_mcp()
    assert REQUIRED_CODING <= set(TOOL_NAMES)


def test_tool_names_include_coord_pack_task7():
    build_mcp()
    assert REQUIRED_COORD <= set(TOOL_NAMES)


def test_tool_names_include_agents_pack_task8():
    build_mcp()
    assert REQUIRED_AGENTS <= set(TOOL_NAMES)


def test_tool_names_include_browser_pack_task9():
    build_mcp()
    assert REQUIRED_BROWSER <= set(TOOL_NAMES)


def test_tool_names_include_research_pack_task10():
    build_mcp()
    assert REQUIRED_RESEARCH <= set(TOOL_NAMES)


def test_build_mcp_returns_app():
    assert build_mcp() is not None


def test_all_design_tool_names_present():
    """Full catalog assert: every design §6.6 pack name is registered."""
    build_mcp()
    required = (
        REQUIRED_CORE
        | REQUIRED_CODING
        | REQUIRED_COORD
        | REQUIRED_AGENTS
        | REQUIRED_BROWSER
        | REQUIRED_RESEARCH
    )
    missing = required - set(TOOL_NAMES)
    assert not missing, f"Missing tool names: {sorted(missing)}"
    assert required <= set(TOOL_NAMES)

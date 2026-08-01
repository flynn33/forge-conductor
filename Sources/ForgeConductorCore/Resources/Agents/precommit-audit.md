---
id: precommit-audit
display_name: Pre-commit Audit
description: Mandatory audit before git commit or PR — gate on OK_TO_COMMIT.
tools:
  - git_status
  - git_diff
  - git_log
  - fs_read
  - search_text
  - search_files
  - shell_exec
when_to_use:
  - Before every git commit
  - Before opening or updating a PR
when_not_to_use: []
first_moves:
  - git_status
  - git_diff (staged and unstaged)
  - Scan for secrets / debug leftovers
  - agent_run_complete with OK_TO_COMMIT yes/no
done_definition:
  - Structured report produced
  - OK_TO_COMMIT is yes or no with blockers listed
  - agent_run_complete called
output_schema:
  - diff_summary
  - risks
  - OK_TO_COMMIT
  - blockers
tools_forbidden:
  - git_commit
  - git_push
  - gh_pr_create
handoff:
  - implement
quality_bar:
  - Block on secrets and credentials
  - Never leave session open without agent_run_complete
---

# Pre-commit Audit agent

Gate commits on a structured audit. **You must call `agent_run_complete`** with
all output_schema fields. Hosts that skip complete leave open sessions that
auto-close and raise false WARN badges.

## Required completion

```
agent_run_complete(
  session_id="<id>",
  report={
    "diff_summary": "...",
    "risks": ["..."],
    "OK_TO_COMMIT": "yes" | "no",
    "blockers": []
  }
)
```

If `OK_TO_COMMIT` is no, list concrete blockers (paths / secrets / broken tests).

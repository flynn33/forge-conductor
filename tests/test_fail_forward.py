from forge_conductor.fail_forward import classify_error, recover, fallbacks_for_tool
from forge_conductor.host_hygiene import patch_jinja_text

def test_classify_jinja():
    c, s = classify_error("applyPromptTemplate 400 No user query found in messages")
    assert c == "jinja_no_user_query"

def test_recover_jinja_auto():
    p = recover(error="Jinja Exception: No user query found in messages.", auto=True)
    assert p["error_class"] == "jinja_no_user_query"
    assert p["fail_forward"] is True
    assert "host_hygiene" in str(p.get("auto_results"))

def test_tool_fallbacks():
    assert "search_files" in fallbacks_for_tool("search_text")

def test_patch_jinja():
    bad = "{%- if ns.multi_step_tool %}\n    {{- raise_exception('No user query found in messages.') }}\n{%- endif %}"
    nt, ok = patch_jinja_text(bad)
    assert ok
    assert "No user query found in messages" not in nt or "last_query_index" in nt

// DashboardHTML.swift
// What: Supplies the minimal native fallback page for the loopback dashboard.
// How: A static Swift string provides controls when packaged resources are unavailable.
// Why: Manager recovery must not depend on a missing or damaged resource bundle.

import Foundation

/// Stores the minimal bootstrap document served at the loopback dashboard root.
///
/// Dashboard behavior and styling live in bundled resources; this document only
/// establishes the DOM shell and loads those versioned assets.
enum DashboardHTML {
    static let index = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Forge-Conductor</title>
<style>
  :root {
    --bg: #0b1020;
    --panel: #121a2f;
    --panel2: #182240;
    --text: #e8eefc;
    --muted: #9aabcc;
    --accent: #5b8cff;
    --ok: #3ecf8e;
    --warn: #f0b429;
    --err: #f07178;
    --border: #243156;
    --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font-family: var(--sans); }
  body { min-height: 100vh; }
  header {
    position: sticky; top: 0; z-index: 10;
    display: flex; align-items: center; justify-content: space-between; gap: 1rem;
    padding: 0.9rem 1.25rem; background: rgba(11,16,32,0.92);
    border-bottom: 1px solid var(--border); backdrop-filter: blur(8px);
  }
  header h1 { margin: 0; font-size: 1.1rem; letter-spacing: 0.02em; }
  header .meta { color: var(--muted); font-size: 0.85rem; font-family: var(--mono); }
  .actions { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center; }
  button, .btn {
    background: var(--panel2); color: var(--text); border: 1px solid var(--border);
    border-radius: 8px; padding: 0.45rem 0.75rem; cursor: pointer; font-size: 0.85rem;
  }
  button:hover { border-color: var(--accent); }
  button:disabled { opacity: 0.45; cursor: not-allowed; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
  button.danger { border-color: var(--err); color: var(--err); }
  button.ok { border-color: var(--ok); color: var(--ok); }
  main { padding: 1.25rem; display: grid; gap: 1rem; grid-template-columns: repeat(12, 1fr); max-width: 1400px; margin: 0 auto; }
  .card {
    background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 1rem;
    grid-column: span 12;
  }
  @media (min-width: 900px) {
    .card.half { grid-column: span 6; }
    .card.third { grid-column: span 4; }
  }
  .card h2 { margin: 0 0 0.75rem; font-size: 0.95rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
  .grid-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 0.75rem; }
  .kpi { background: var(--panel2); border-radius: 10px; padding: 0.75rem; }
  .kpi .v { font-size: 1.4rem; font-weight: 650; font-family: var(--mono); }
  .kpi .l { color: var(--muted); font-size: 0.75rem; margin-top: 0.2rem; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td { text-align: left; padding: 0.45rem 0.35rem; border-bottom: 1px solid var(--border); vertical-align: top; }
  th { color: var(--muted); font-weight: 600; }
  .pill { display: inline-block; padding: 0.1rem 0.45rem; border-radius: 999px; font-size: 0.75rem; font-family: var(--mono); }
  .pill.ok { background: rgba(62,207,142,0.15); color: var(--ok); }
  .pill.warn { background: rgba(240,180,41,0.15); color: var(--warn); }
  .pill.err { background: rgba(240,113,120,0.15); color: var(--err); }
  .pill.open { background: rgba(91,140,255,0.15); color: var(--accent); }
  pre, .mono { font-family: var(--mono); font-size: 0.78rem; white-space: pre-wrap; word-break: break-word; color: var(--muted); }
  .muted { color: var(--muted); }
  .err-banner { display:none; background: rgba(240,113,120,0.12); border: 1px solid var(--err); color: var(--err); padding: 0.6rem 0.8rem; border-radius: 8px; margin-bottom: 0.5rem; }
  .warn-banner { display:none; background: rgba(240,180,41,0.12); border: 1px solid var(--warn); color: var(--warn); padding: 0.6rem 0.8rem; border-radius: 8px; margin-bottom: 0.5rem; }
  .form-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 0.75rem; }
  label { display: block; font-size: 0.75rem; color: var(--muted); margin-bottom: 0.25rem; }
  input[type=text], input[type=number], select {
    width: 100%; background: var(--panel2); border: 1px solid var(--border); color: var(--text);
    border-radius: 8px; padding: 0.45rem 0.55rem; font-family: var(--mono); font-size: 0.85rem;
  }
  .check { display: flex; align-items: center; gap: 0.45rem; margin-top: 1.35rem; font-size: 0.85rem; }
  .row { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center; margin-top: 0.75rem; }
  .ops-dim { opacity: 0.55; pointer-events: none; }
</style>
</head>
<body>
<header>
  <div>
    <h1>Forge-Conductor · Web control (native app is primary)</h1>
    <div class="meta" id="header-meta">loading…</div>
  </div>
  <div class="actions">
    <a class="btn primary" href="/" id="telemetry-dash-link" style="text-decoration:none;display:inline-block">← Telemetry dashboard</a>
    <span id="svc-pill" class="pill warn">…</span>
    <button class="ok" id="btn-start" onclick="mgrStart()">Start</button>
    <button class="danger" id="btn-stop" onclick="mgrStop()">Stop</button>
    <button id="btn-restart" onclick="mgrRestart()">Restart</button>
    <button class="primary" onclick="refreshAll()">Refresh</button>
    <button onclick="pruneSessions()">Prune stale</button>
    <button onclick="runDoctor()">Doctor</button>
  </div>
</header>
<main>
  <div class="card">
    <div id="err" class="err-banner"></div>
    <div id="svc-warn" class="warn-banner"></div>
    <div class="grid-kpis" id="kpis"></div>
  </div>

  <div class="card half">
    <h2>Manager node</h2>
    <div id="manager-panel" class="muted">—</div>
    <div class="row">
      <button class="ok" onclick="mgrStart()">Start service</button>
      <button class="danger" onclick="mgrStop()">Stop service</button>
      <button onclick="mgrRestart()">Restart service</button>
      <button class="danger" onclick="mgrShutdown()">Shutdown manager</button>
    </div>
    <p class="muted" style="margin:0.75rem 0 0;font-size:0.8rem">
      Stop pauses operational APIs but keeps this control surface up.
      Shutdown ends the manager process (start again with <span class="mono">forge-conductor manager run</span>).
    </p>
  </div>

  <div class="card half">
    <h2>Settings</h2>
    <div class="form-grid">
      <div>
        <label for="set-host">Dashboard host</label>
        <input id="set-host" type="text" value="127.0.0.1"/>
      </div>
      <div>
        <label for="set-port">Dashboard port</label>
        <input id="set-port" type="number" min="1" max="65535" value="7788"/>
      </div>
      <div>
        <label for="set-refresh">UI refresh (sec)</label>
        <input id="set-refresh" type="number" min="2" max="300" value="8"/>
      </div>
      <div>
        <label for="set-watchdog">Watchdog (sec)</label>
        <input id="set-watchdog" type="number" min="1" max="60" value="3"/>
      </div>
      <div>
        <label for="set-idle">Session idle TTL (sec)</label>
        <input id="set-idle" type="number" min="60" value="14400"/>
      </div>
      <div>
        <label for="set-shell">Shell timeout (sec)</label>
        <input id="set-shell" type="number" min="1" max="600" value="30"/>
      </div>
      <div class="check">
        <input id="set-auto" type="checkbox" checked/>
        <label for="set-auto" style="margin:0">Auto-restart HTTP if it drops</label>
      </div>
      <div class="check">
        <input id="set-open" type="checkbox"/>
        <label for="set-open" style="margin:0">Open browser on manager start</label>
      </div>
    </div>
    <div class="row">
      <button class="primary" onclick="saveSettings()">Save settings</button>
      <button onclick="loadSettings()">Reload form</button>
      <span id="settings-msg" class="muted"></span>
    </div>
  </div>

  <div id="ops" class="card half">
    <h2>Open sessions</h2>
    <div id="sessions" class="muted">—</div>
  </div>
  <div class="card half ops-section">
    <h2>Agents</h2>
    <div id="agents" class="muted">—</div>
  </div>
  <div class="card half ops-section">
    <h2>Recent audit</h2>
    <div id="audit" class="muted">—</div>
  </div>
  <div class="card half ops-section">
    <h2>Diagnostics (tail)</h2>
    <pre id="diagnostics">—</pre>
  </div>
  <div class="card ops-section">
    <h2>Doctor</h2>
    <div id="doctor" class="muted">Run doctor to validate install.</div>
  </div>
</main>
<script>
const $ = (id) => document.getElementById(id);
let refreshTimer = null;
let refreshSec = 8;
let hasManager = false;
let serviceActive = true;

function showErr(msg) {
  const el = $('err');
  if (!msg) { el.style.display = 'none'; el.textContent = ''; return; }
  el.style.display = 'block'; el.textContent = msg;
}
function showSvcWarn(msg) {
  const el = $('svc-warn');
  if (!msg) { el.style.display = 'none'; el.textContent = ''; return; }
  el.style.display = 'block'; el.textContent = msg;
}
async function jget(path) {
  const r = await fetch(path, { cache: 'no-store' });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const err = new Error(j.message || (path + ' → ' + r.status));
    err.payload = j;
    err.status = r.status;
    throw err;
  }
  return j;
}
async function jpost(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {})
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok && r.status >= 500) {
    throw new Error(j.message || (path + ' → ' + r.status));
  }
  return j;
}
function pill(status) {
  const s = (status || '').toLowerCase();
  let cls = 'ok';
  if (s === 'warn' || s === 'warning' || s === 'stopped' || s === 'stopping') cls = 'warn';
  else if (s === 'error' || s === 'failed' || s === 'err') cls = 'err';
  else if (s === 'open' || s === 'running' || s === 'active' || s === 'starting' || s === 'restarting') cls = 'open';
  return `<span class="pill ${cls}">${status || '?'}</span>`;
}
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function setServiceUI(active, state) {
  serviceActive = !!active;
  $('svc-pill').className = 'pill ' + (active ? 'ok' : (state === 'failed' ? 'err' : 'warn'));
  $('svc-pill').textContent = active ? 'service: running' : ('service: ' + (state || 'stopped'));
  document.querySelectorAll('.ops-section').forEach(el => {
    if (active) el.classList.remove('ops-dim'); else el.classList.add('ops-dim');
  });
  if (active) showSvcWarn('');
  else showSvcWarn('Operational APIs are paused. Manager control surface remains available — press Start to resume.');
}
function renderManager(m) {
  if (!m || m.manager === false || m.state === 'standalone') {
    hasManager = false;
    $('manager-panel').innerHTML = `<span class="muted">Standalone dashboard (no manager). Run <span class="mono">forge-conductor manager run</span> for supervised control.</span>`;
    setServiceUI(true, 'standalone');
    return;
  }
  hasManager = true;
  const dash = m.dashboard || {};
  $('manager-panel').innerHTML = `
    <table>
      <tr><th>State</th><td>${pill(m.state)} ${m.service_active ? pill('active') : pill('paused')}</td></tr>
      <tr><th>HTTP</th><td class="mono">${esc(dash.url || '')} · listening ${m.http_listening ? 'yes' : 'no'}</td></tr>
      <tr><th>PID</th><td class="mono">${esc(m.pid)}</td></tr>
      <tr><th>Uptime</th><td class="mono">${esc(m.uptime_sec ?? '—')}s · restarts ${esc(m.restart_count ?? 0)}</td></tr>
      <tr><th>Auto-restart</th><td>${m.auto_restart ? 'on' : 'off'} · watchdog ${esc(m.watchdog_interval_sec)}s</td></tr>
      <tr><th>Last error</th><td class="mono">${esc(m.last_error || '—')}</td></tr>
    </table>`;
  setServiceUI(!!m.service_active, m.state);
}
async function loadSettings() {
  try {
    const s = await jget('/api/manager/settings');
    const d = s.dashboard || {};
    const m = s.manager || {};
    const sess = s.sessions || {};
    const shell = s.shell || {};
    $('set-host').value = d.host || '127.0.0.1';
    $('set-port').value = d.port ?? 7788;
    $('set-refresh').value = d.refresh_interval_sec ?? 8;
    $('set-watchdog').value = m.watchdog_interval_sec ?? 3;
    $('set-idle').value = sess.idle_ttl_sec ?? 14400;
    $('set-shell').value = shell.default_timeout_sec ?? 30;
    $('set-auto').checked = m.auto_restart !== false;
    $('set-open').checked = !!m.open_browser_on_start;
    refreshSec = Number(d.refresh_interval_sec) || 8;
    scheduleRefresh();
  } catch (e) {
    // no manager — keep defaults
  }
}
async function saveSettings() {
  try {
    $('settings-msg').textContent = 'Saving…';
    const body = {
      apply: true,
      dashboard: {
        host: $('set-host').value.trim(),
        port: Number($('set-port').value),
        refresh_interval_sec: Number($('set-refresh').value),
      },
      manager: {
        auto_restart: $('set-auto').checked,
        open_browser_on_start: $('set-open').checked,
        watchdog_interval_sec: Number($('set-watchdog').value),
      },
      sessions: { idle_ttl_sec: Number($('set-idle').value) },
      shell: { default_timeout_sec: Number($('set-shell').value) },
    };
    const r = await jpost('/api/manager/settings', body);
    $('settings-msg').textContent = r.bind_changed
      ? 'Saved — listener rebound to new host/port.'
      : 'Saved.';
    refreshSec = Number($('set-refresh').value) || 8;
    scheduleRefresh();
    await refreshAll();
  } catch (e) {
    $('settings-msg').textContent = String(e);
    showErr(String(e));
  }
}
async function mgrStart() {
  try { await jpost('/api/manager/start', {}); await refreshAll(); }
  catch (e) { showErr(String(e)); }
}
async function mgrStop() {
  try { await jpost('/api/manager/stop', {}); await refreshAll(); }
  catch (e) { showErr(String(e)); }
}
async function mgrRestart() {
  try {
    showErr('');
    $('header-meta').textContent = 'restarting…';
    await jpost('/api/manager/restart', {});
    // brief wait if HTTP bounced
    await new Promise(r => setTimeout(r, 400));
    await refreshAll();
  } catch (e) {
    // restart may drop connection mid-flight
    await new Promise(r => setTimeout(r, 600));
    try { await refreshAll(); } catch (e2) { showErr(String(e2)); }
  }
}
async function mgrShutdown() {
  if (!confirm('Shutdown the manager process? The dashboard will go offline until you run: forge-conductor manager run')) return;
  try {
    await jpost('/api/manager/shutdown', {});
    $('header-meta').textContent = 'manager shutting down…';
    showSvcWarn('Manager process is shutting down. Start it again from the CLI.');
  } catch (e) { showErr(String(e)); }
}
async function refreshAll() {
  try {
    showErr('');
    let status;
    try {
      status = await jget('/api/status');
    } catch (e) {
      // try manager status alone
      try {
        const m = await jget('/api/manager/status');
        renderManager(m);
        $('header-meta').textContent = `manager ${m.state} · pid ${m.pid}`;
      } catch (_) {}
      throw e;
    }
    const mgr = status.manager || {};
    renderManager(mgr);
    $('header-meta').textContent =
      `${status.version || ''} · ${status.home || ''} · pid ${status.pid || ''}` +
      (mgr.state ? ` · mgr ${mgr.state}` : '');

    $('kpis').innerHTML = [
      ['Service', status.service_active === false ? 'paused' : 'up'],
      ['Open sessions', status.open_session_count ?? 0],
      ['Agents', status.agent_count ?? 0],
      ['Presence', status.presence_count ?? 0],
      ['Runtime', status.runtime || 'swift'],
    ].map(([l,v]) => `<div class="kpi"><div class="v">${esc(v)}</div><div class="l">${esc(l)}</div></div>`).join('');

    if (status.service_active === false) {
      $('sessions').innerHTML = '<span class="muted">Service stopped.</span>';
      $('agents').innerHTML = '<span class="muted">Service stopped.</span>';
      $('audit').innerHTML = '<span class="muted">Service stopped.</span>';
      $('diagnostics').textContent = 'Service stopped.';
      return;
    }

    const [sessions, agents, audit, diag] = await Promise.all([
      jget('/api/sessions'),
      jget('/api/agents'),
      jget('/api/audit'),
      jget('/api/diagnostics'),
    ]);

    const open = sessions.open || [];
    if (!open.length) {
      $('sessions').innerHTML = '<span class="muted">No open sessions.</span>';
    } else {
      $('sessions').innerHTML = `<table><thead><tr><th>Agent</th><th>Status</th><th>Updated</th><th></th></tr></thead><tbody>` +
        open.map(s => `<tr>
          <td class="mono">${esc(s.agent_id)}<div class="muted">${esc(s.id)}</div></td>
          <td>${pill(s.status)}</td>
          <td class="mono">${esc(s.updated_at)}</td>
          <td><button onclick="closeSession('${esc(s.id)}')">Close</button></td>
        </tr>`).join('') + `</tbody></table>`;
    }

    const list = agents.agents || [];
    $('agents').innerHTML = `<table><thead><tr><th>ID</th><th>Name</th><th>Source</th></tr></thead><tbody>` +
      list.map(a => `<tr><td class="mono">${esc(a.id)}</td><td>${esc(a.display_name)}</td><td class="muted">${esc(a.source)}</td></tr>`).join('') +
      `</tbody></table>`;

    const events = audit.events || [];
    $('audit').innerHTML = events.length ? (`<table><thead><tr><th>Time</th><th>Tool</th><th>Status</th><th>ms</th></tr></thead><tbody>` +
      events.slice(0, 40).map(e => `<tr>
        <td class="mono">${esc(e.timestamp)}</td>
        <td class="mono">${esc(e.tool)}</td>
        <td>${pill(e.status)}</td>
        <td class="mono">${esc(e.duration_ms ?? '')}</td>
      </tr>`).join('') + `</tbody></table>`) : '<span class="muted">No audit events yet.</span>';

    const lines = diag.lines || [];
    $('diagnostics').textContent = lines.length ? lines.join('\n') : 'No diagnostics yet.';
  } catch (e) {
    showErr(String(e));
  }
}
async function pruneSessions() {
  try { await jpost('/api/sessions/prune', {}); await refreshAll(); }
  catch (e) { showErr(String(e)); }
}
async function closeSession(id) {
  try {
    await jpost('/api/sessions/close', { session_id: id, summary: 'Closed from dashboard' });
    await refreshAll();
  } catch (e) { showErr(String(e)); }
}
async function runDoctor() {
  try {
    const d = await jget('/api/doctor');
    const rows = (d.checks || []).map(c =>
      `<tr><td>${pill(c.ok ? 'ok' : 'error')}</td><td class="mono">${esc(c.name)}</td><td>${esc(c.detail)}</td></tr>`
    ).join('');
    $('doctor').innerHTML = `<div class="muted" style="margin-bottom:0.5rem">overall ${d.ok ? 'OK' : 'ISSUES'} · ${esc(d.home || '')}</div>
      <table><thead><tr><th></th><th>Check</th><th>Detail</th></tr></thead><tbody>${rows}</tbody></table>`;
  } catch (e) { showErr(String(e)); }
}
function scheduleRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(refreshAll, Math.max(2, refreshSec) * 1000);
}
loadSettings().then(refreshAll);
scheduleRefresh();
</script>
</body>
</html>
"""#
}

/* Forge Rig Telemetry — system + orchestration + MCP */
(() => {
  const $ = (id) => document.getElementById(id);
  const hist = { t: [], cpu: [], gpu: [], ram: [], disk: [], epm: [] };
  const MAX = 90;
  let lastOk = 0;
  let es = null;
  let pollTimer = null;
  let seenFeed = new Set();
  let feedPrimed = false;

  function setBoot(msg, cls) {
    const el = $("boot-banner");
    if (!el) return;
    el.textContent = msg;
    el.className = cls || "";
    // Hide success banner after first good paint
    if (cls === "ok") {
      setTimeout(() => {
        if (el.className === "ok") el.style.display = "none";
      }, 2500);
    } else {
      el.style.display = "";
    }
  }

  setBoot("Connecting to realtime stream /api/stream…", "");

  function n(v, fallback = 0) {
    const x = Number(v);
    return Number.isFinite(x) ? x : fallback;
  }

  function setMeter(id, pct) {
    const el = $(id);
    if (!el) return;
    el.style.width = `${Math.max(0, Math.min(100, n(pct, 0)))}%`;
  }

  function fmtTime(ts) {
    if (ts == null || ts === "") return "—";
    try {
      if (typeof ts === "number") return new Date(ts * 1000).toLocaleTimeString();
      return new Date(ts).toLocaleTimeString();
    } catch {
      return String(ts).slice(11, 19);
    }
  }

  function fmtTimeShort(ts) {
    const s = fmtTime(ts);
    if (s === "—") return s;
    const m = String(s).match(/(\d{1,2}:\d{2}:\d{2})/);
    return m ? m[1] : s;
  }

  function pushHist(snap) {
    hist.t.push(snap.ts || Date.now() / 1000);
    hist.cpu.push(snap.cpu != null ? n(snap.cpu, null) : null);
    hist.gpu.push(snap.gpu != null ? n(snap.gpu, null) : null);
    hist.ram.push(snap.ram != null ? n(snap.ram, null) : null);
    hist.disk.push(snap.disk != null ? n(snap.disk, null) : null);
    hist.epm.push(snap.mcp_epm_5m != null ? n(snap.mcp_epm_5m, null) : null);
    while (hist.t.length > MAX) {
      for (const k of Object.keys(hist)) hist[k].shift();
    }
  }

  function drawChart() {
    const canvas = $("chart");
    if (!canvas || !canvas.parentElement) return;
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.parentElement.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) return;
    canvas.width = Math.floor(rect.width * dpr);
    canvas.height = Math.floor(rect.height * dpr);
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const w = rect.width;
    const h = rect.height;
    ctx.clearRect(0, 0, w, h);

    ctx.strokeStyle = "rgba(24, 240, 255, 0.12)";
    ctx.lineWidth = 1;
    for (let i = 0; i <= 3; i++) {
      const y = (h * i) / 3;
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
      ctx.stroke();
    }

    const series = [
      { key: "cpu", color: "#18f0ff", max: 100 },
      { key: "gpu", color: "#2dff9a", max: 100 },
      { key: "ram", color: "#7cf0ff", max: 100 },
      { key: "disk", color: "#ffc14a", max: null },
      { key: "epm", color: "#ff6a1a", max: null },
    ];
    const diskVals = hist.disk.filter((x) => x != null && Number.isFinite(x));
    const epmVals = hist.epm.filter((x) => x != null && Number.isFinite(x));
    const diskMax = Math.max(5, ...(diskVals.length ? diskVals : [1]), 1);
    const epmMax = Math.max(5, ...(epmVals.length ? epmVals : [1]), 1);

    for (const s of series) {
      const arr = hist[s.key];
      let max = s.max;
      if (s.key === "disk") max = diskMax;
      if (s.key === "epm") max = epmMax;
      ctx.strokeStyle = s.color;
      ctx.shadowColor = s.color;
      ctx.shadowBlur = 6;
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      let started = false;
      for (let i = 0; i < arr.length; i++) {
        const v = arr[i];
        if (v == null || Number.isNaN(v)) continue;
        const x = arr.length <= 1 ? 0 : (i / (arr.length - 1)) * (w - 4) + 2;
        const y = h - 3 - (Math.min(v, max) / max) * (h - 8);
        if (!started) {
          ctx.moveTo(x, y);
          started = true;
        } else ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.shadowBlur = 0;
    }
  }

  function setText(id, text) {
    const el = $(id);
    if (el) el.textContent = text;
  }

  function setHtml(id, html) {
    const el = $(id);
    if (el) el.innerHTML = html;
  }

  function esc(s) {
    return String(s ?? "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function ringHtml(activity, label) {
    const p = Math.max(0, Math.min(100, n(activity, 0)));
    const hot = p >= 70 ? " hot" : "";
    return `<div class="ring${hot}" style="--p:${p}"><span>${Math.round(p)}</span></div>
      <div class="ring-stats">${label}</div>`;
  }

  function healthBadge(health, fallbackLabel) {
    const h = (health || "ok").toLowerCase();
    // Green READY · Yellow WARN · Orange ERROR · Red DOWN
    const map = {
      ok: { cls: "health-ok", text: "READY" },
      ready: { cls: "health-ok", text: "READY" },
      active: { cls: "health-ok", text: "READY" },
      warn: { cls: "health-warn", text: "WARN" },
      warning: { cls: "health-warn", text: "WARN" },
      error: { cls: "health-error", text: "ERROR" },
      failed: { cls: "health-error", text: "ERROR" },
      down: { cls: "health-down", text: "DOWN" },
      config: { cls: "health-config", text: "CONFIG" },
    };
    const m = map[h] || map.ok;
    const text = fallbackLabel || m.text;
    return { cls: `ec-role ${m.cls}`, text, healthCls: m.cls };
  }

  function renderCoreBars(perCpu) {
    const root = $("core-bars");
    if (!root) return;
    const cores = Array.isArray(perCpu) ? perCpu : [];
    if (!cores.length) {
      root.innerHTML = `<div class="empty-hint">NO PER-CORE DATA</div>`;
      return;
    }
    root.innerHTML = cores
      .map((pct, i) => {
        const p = Math.max(0, Math.min(100, n(pct, 0)));
        const hot = p >= 75 ? " hot" : "";
        return `<div class="core-cell" title="Core ${i}: ${p.toFixed(1)}%">
          <div class="core-pct">${Math.round(p)}</div>
          <div class="core-track"><div class="core-fill${hot}" style="height:${p}%"></div></div>
          <div class="core-id">C${i}</div>
        </div>`;
      })
      .join("");
  }

  function renderDiskList(disks, diskIo) {
    const root = $("disk-list");
    if (!root) return;
    const list = disks || [];
    const io = diskIo || {};
    const ioBlock = `
      <div class="disk-io-stats">
        <div>READ<strong>${n(io.read_mb_s, 0).toFixed(1)} MB/s</strong>${n(io.read_iops, 0).toFixed(0)} IOPS</div>
        <div>WRITE<strong>${n(io.write_mb_s, 0).toFixed(1)} MB/s</strong>${n(io.write_iops, 0).toFixed(0)} IOPS</div>
        <div>TOTAL<strong>${n(io.total_mb_s, 0).toFixed(1)} MB/s</strong>${n(io.total_iops, 0).toFixed(0)} IOPS</div>
      </div>`;

    if (!list.length) {
      root.innerHTML = ioBlock + `<div class="empty-hint">NO VOLUME DATA</div>`;
      return;
    }

    const volHtml = list
      .slice(0, 4)
      .map((d) => {
        const pct = Math.max(0, Math.min(100, n(d.percent, 0)));
        return `<div class="disk-row">
          <div class="disk-row-top">
            <span class="mount">${esc(d.mount)}</span>
            <span class="size">${n(d.used_gb, 0).toFixed(0)}/${n(d.total_gb, 0).toFixed(0)} GB · ${pct.toFixed(0)}%</span>
          </div>
          <div class="meter"><i style="width:${pct}%"></i></div>
          <div class="sys-meta" style="margin-top:6px">${esc(d.fstype || "")} · ${esc(d.device || "")}</div>
        </div>`;
      })
      .join("");
    root.innerHTML = ioBlock + volHtml;
  }

  function renderOrchestration(orch) {
    const root = $("orch-cards");
    const log = $("orch-log");
    if (!root) return;
    const o = orch || {};
    const hb = o.heartbeat || {};
    const health = o.health || "config";
    const badge = healthBadge(health, o.health_label);
    const src = hb.source || "—";

    function roleCard(name, live, pid, extra) {
      const isLive = live === true;
      // Only label "dead" when we positively know it should exist but doesn't
      let status;
      if (isLive) status = "alive";
      else if (live === false && (pid || health === "error")) status = "down";
      else status = "standby";
      return {
        name,
        live: isLive,
        pid: pid || null,
        status: extra ? `${status} · ${extra}` : status,
      };
    }

    const mode = o.mode || (o.manager_alive ? "swift-manager" : "legacy");
    const cards = [];

    // Swift manager is the supported control plane after Python cleanup
    if (mode === "swift-manager" || o.manager_alive) {
      cards.push(
        roleCard(
          "MANAGER",
          o.manager_alive === true,
          o.manager_pid || hb.manager_pid,
          o.manager_state?.state || "swift"
        )
      );
      cards.push({
        name: "HTTP",
        live:
          o.manager_state?.http_listening === true ||
          o.manager_state?.service_active === true ||
          o.manager_alive === true,
        pid: null,
        status:
          o.manager_state?.service_active === true
            ? "service active"
            : o.manager_state?.http_listening === true
              ? "listening"
              : o.manager_alive
                ? "manager up"
                : "down",
      });
      cards.push({
        name: "MCP PROCS",
        live: n(o.mcp_external_count, 0) > 0 || n(o.serve_count, 0) > 0,
        pid: (hb.mcp_external_pids || hb.serve_pids || [])[0] || null,
        status: `${n(o.mcp_external_count, 0)} local · ${n(o.serve_count, 0)} serve`,
      });
    } else {
      cards.push(roleCard("PRIMARY", o.primary_alive, hb.primary_pid, "keeper"));
      cards.push(roleCard("FALLBACK", o.fallback_alive, hb.fallback_pid, "keeper"));
      cards.push(roleCard("WATCHDOG", o.watchdog_alive, hb.watchdog_pid, null));
      cards.push(
        roleCard("ORCHESTRATOR", o.orchestrator_alive, hb.orchestrator_pid, null)
      );
      cards.push({
        name: "SERVE",
        live: n(o.serve_count, 0) > 0,
        pid: (hb.serve_pids || [])[0] || null,
        status: `${n(o.serve_count, 0)} proc · ${n(o.supervise_count, 0)} sup`,
      });
    }

    cards.push({
      name: "STATUS",
      live:
        (o.manager_alive === true) ||
        (o.heartbeat_age_sec != null && o.heartbeat_age_sec < 45) ||
        health === "ok",
      pid: null,
      status:
        o.heartbeat_age_sec != null
          ? `${o.heartbeat_age_sec}s · ${src}`
          : `src ${src}`,
    });

    root.innerHTML = cards
      .map((c) => {
        const h = c.live ? "ok" : health === "error" ? "error" : "warn";
        const badgeTxt = c.live ? "UP" : c.status === "down" ? "DOWN" : "—";
        return `<div class="entity-card health-${h} ${c.live ? "live" : "stale"}">
          <div class="ec-top">
            <div class="ec-name">${esc(c.name)}</div>
            <div class="ec-role health-${h}">${badgeTxt}</div>
          </div>
          <div class="ec-status health-${h}">${esc(c.status)}</div>
          <div class="ec-meta">pid ${esc(c.pid ?? "—")}</div>
        </div>`;
      })
      .join("");

    setText(
      "orch-panel-meta",
      `${badge.text} · ${mode === "swift-manager" || o.manager_alive ? "MANAGER" : "LEGACY"} · MCP ${n(o.mcp_external_count, 0)} · SERVE ${n(o.serve_count, 0)} · ${src} ${o.heartbeat_age_sec != null ? o.heartbeat_age_sec + "s" : ""}`
    );

    if (log) {
      const lines = [
        ...(o.supervisor_tail || []).map((ln) => ({ ln, role: /\[primary\]/i.test(ln) ? "primary" : /\[fallback\]/i.test(ln) ? "fallback" : "" })),
        ...(o.orchestrator_tail || []).map((ln) => ({ ln, role: "" })),
      ].slice(-12);
      if (!lines.length) {
        log.innerHTML = `<div class="empty-hint">NO ORCHESTRATION LOGS</div>`;
      } else {
        log.innerHTML = lines
          .map(
            (x) =>
              `<div class="ln${x.role ? " role-" + x.role : ""}" title="${esc(x.ln)}">${esc(x.ln)}</div>`
          )
          .join("");
        log.scrollTop = log.scrollHeight;
      }
    }

    const pill = $("pill-orch");
    if (pill) {
      pill.textContent = `ORCH ${o.health_label || "—"}`;
      if (health === "error") pill.className = "pill bad";
      else if (health === "warn" || health === "config") pill.className = "pill warn";
      else pill.className = "pill live";
    }
  }

  function renderProcesses(procs) {
    const body = $("proc-body");
    if (!body) return;
    const list = procs || [];
    if (!list.length) {
      body.innerHTML = `<tr><td colspan="4" class="empty-hint">NO MATCHING PROCESSES</td></tr>`;
      return;
    }
    body.innerHTML = list
      .slice(0, 12)
      .map(
        (p) => `<tr>
          <td class="num">${esc(p.pid)}</td>
          <td>${esc(p.name)}</td>
          <td class="num">${n(p.cpu_percent, 0).toFixed(1)}</td>
          <td class="num">${n(p.rss_gb, 0).toFixed(2)} GB</td>
        </tr>`
      )
      .join("");
  }

  function renderMcpCards(servers) {
    const root = $("mcp-cards");
    if (!root) return;
    root.innerHTML = "";
    if (!servers || !servers.length) {
      root.innerHTML = `<div class="empty-hint">NO MCP PRESENCE — WAITING FOR HEARTBEAT</div>`;
      return;
    }
    for (const s of servers) {
      const health = s.health || (s.live ? "ok" : "error");
      const badge = healthBadge(health, s.health_label);
      const cls = [
        "entity-card",
        `health-${health}`,
        s.live ? "live" : "stale",
        s.status === "active" ? "active" : "",
        s.status === "idle" ? "idle" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const u = s.usage_5m || {};
      const tools = (u.top_tools || [])
        .slice(0, 4)
        .map((t) => {
          const name = Array.isArray(t) ? t[0] : t;
          const c = Array.isArray(t) ? t[1] : "";
          return `<span>${esc(name)}×${esc(c)}</span>`;
        })
        .join("");
      const card = document.createElement("div");
      card.className = cls;
      card.title = `${s.label} · ${s.role} · ${s.health_label || health} · ${s.health_reason || ""}`;
      card.innerHTML = `
        <div class="ec-top">
          <div class="ec-name">${esc(s.label)}</div>
          <div class="${badge.cls}" title="${esc(s.health_reason || badge.text)}">${esc(badge.text)}</div>
        </div>
        <div class="ec-status health-${esc(health)}">${esc(s.role || "mcp")} · ${esc(s.status)}${s.live ? " · LINK" : ""}</div>
        <div class="ring-wrap">
          ${ringHtml(
            s.activity,
            `<div><strong>${n(u.events_per_min, 0)}</strong> evt/min</div>
             <div>${n(u.event_count, 0)} calls · 5m</div>
             <div>err ${n(u.error_rate, 0)}</div>`
          )}
        </div>
        <div class="ec-meta">
          pid ${esc(s.pid ?? "—")} · hb ${s.heartbeat_age_sec != null ? s.heartbeat_age_sec + "s" : "—"}
          <br/>last ${esc(u.last_tool || "—")} · ${fmtTimeShort(u.last_ts)}
        </div>
        <div class="ec-tools">${tools || `<span>idle</span>`}</div>
      `;
      root.appendChild(card);
    }
  }

  function renderPackStrip(packs) {
    const root = $("pack-strip");
    if (!root) return;
    root.innerHTML = "";
    for (const p of packs || []) {
      const el = document.createElement("div");
      const hot = (p.active_tools || 0) > 0 || (p.event_count_1h || 0) > 0;
      el.className = "pack-chip" + (hot ? " hot" : "");
      el.innerHTML = `<span class="pip"></span>${esc(p.pack)} <strong>${n(p.event_count_1h, 0)}</strong>`;
      el.title = `${p.tool_count} tools · ${p.active_tools || 0} active · ${p.event_count_1h || 0} calls / 1h`;
      root.appendChild(el);
    }
  }

  function shortToolLabel(tool) {
    const parts = String(tool || "")
      .split(/[_\s]+/)
      .filter(Boolean);
    if (!parts.length) return "?";
    return parts[0].toUpperCase();
  }

  function loadTier(activity, status) {
    const a = n(activity, 0);
    if (a >= 55 || status === "active") return 3;
    if (a >= 25 || status === "warm") return 2;
    if (a > 0) return 1;
    return 0;
  }

  function renderToolCards(tools) {
    const root = $("tool-cards");
    if (!root) return;
    root.innerHTML = "";
    const list = tools || [];
    if (!list.length) {
      root.innerHTML = `<div class="empty-hint">NO TOOL CATALOG</div>`;
      return;
    }
    for (const t of list) {
      const u = t.usage_1h || {};
      const u5 = t.usage_5m || {};
      const health = t.health || "ok";
      const load = loadTier(t.activity, t.status);
      const short = shortToolLabel(t.tool);
      const card = document.createElement("div");
      card.className = `tool-tile load-${load} health-${health}`;
      card.title = [
        t.tool,
        `pack ${t.pack}`,
        t.health_label || "READY",
        t.health_reason || "",
        `load ${load}/3 · activity ${n(t.activity, 0)}`,
        `${n(u.event_count, 0)}/1h · ${n(u5.event_count, 0)}/5m`,
      ]
        .filter(Boolean)
        .join(" · ");
      card.innerHTML = `<span class="tool-short health-${esc(health)}">${esc(short)}</span>`;
      root.appendChild(card);
    }
  }

  function renderAgentCards(agents) {
    const root = $("agent-cards");
    if (!root) return;
    root.innerHTML = "";
    const list = agents || [];
    if (!list.length) {
      root.innerHTML = `<div class="empty-hint">NO AGENTS REGISTERED</div>`;
      return;
    }
    const priority = { active: 0, warn: 1, error: 2, down: 3, ready: 4, idle: 4 };
    const show = [...list]
      .sort((a, b) => {
        if (a.live !== b.live) return a.live ? -1 : 1;
        return (priority[a.status] ?? 9) - (priority[b.status] ?? 9);
      })
      .slice(0, 16);

    for (const a of show) {
      const health = (a.health || "ok").toLowerCase();
      const badge = healthBadge(health, a.health_label);
      const healthCls =
        health === "down"
          ? "health-down"
          : health === "error" || health === "failed"
            ? "health-error"
            : health === "warn" || health === "warning"
              ? "health-warn"
              : "health-ok";
      const cls = [
        "entity-card",
        "agent-card",
        healthCls,
        a.live ? "live" : "",
        a.status === "active" || a.status === "open" ? "active" : "",
        a.status === "ready" || a.status === "idle" ? "ready" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const u = a.usage_15m || {};
      const sess = (a.sessions || []).length;
      const statusLine =
        a.status === "active"
          ? "active run"
          : a.status === "ready" || a.status === "idle"
            ? "standby"
            : a.status === "warn"
              ? "needs attention"
              : a.status === "error"
                ? "last run failed"
                : a.status === "down"
                  ? "unavailable"
                  : String(a.status || "—");
      const card = document.createElement("div");
      card.className = cls;
      card.title = [
        a.agent_id,
        a.health_label || badge.text,
        a.health_reason || "",
        a.last_session_status ? `last session: ${a.last_session_status}` : "",
      ]
        .filter(Boolean)
        .join(" · ");
      card.innerHTML = `
        <div class="ec-top">
          <div class="ec-name">${esc(a.agent_id)}</div>
          <div class="${badge.cls}" title="${esc(a.health_reason || badge.text)}">
            <span class="status-pip ${healthCls}"></span>${esc(badge.text)}
          </div>
        </div>
        <div class="ec-status ${healthCls}">${esc(statusLine)}</div>
        <div class="agent-health-bar ${healthCls}" aria-hidden="true"></div>
        <div class="ring-wrap">
          ${ringHtml(
            a.activity,
            `<div><strong>${n(u.event_count, 0)}</strong> calls</div>
             <div>${n(u.events_per_min, 0)}/min · 15m</div>
             <div>${sess} session${sess === 1 ? "" : "s"}</div>`
          )}
        </div>
        <div class="ec-meta">
          ${u.last_tool ? `last ${esc(u.last_tool)}` : "standby"}
          ${a.last_ts ? ` · ${fmtTimeShort(a.last_ts)}` : ""}
          ${a.health_reason ? `<br/>${esc(a.health_reason)}` : ""}
        </div>
      `;
      root.appendChild(card);
    }
  }

  function renderFeed(items) {
    const root = $("live-feed");
    if (!root) return;
    const list = items || [];

    if (!feedPrimed) {
      root.innerHTML = "";
      seenFeed = new Set();
      const chronological = [...list].reverse();
      for (const e of chronological) {
        seenFeed.add(e.id);
        root.appendChild(makeFeedLine(e, false));
      }
      feedPrimed = true;
      root.scrollTop = root.scrollHeight;
      return;
    }

    const newestFirst = list;
    const toAdd = [];
    for (const e of newestFirst) {
      if (seenFeed.has(e.id)) break;
      toAdd.push(e);
    }
    toAdd.reverse();
    for (const e of toAdd) {
      seenFeed.add(e.id);
      root.appendChild(makeFeedLine(e, true));
    }
    while (root.children.length > 100) {
      const first = root.firstElementChild;
      if (first) root.removeChild(first);
    }
    if (toAdd.length) root.scrollTop = root.scrollHeight;
  }

  function makeFeedLine(e, isNew) {
    const line = document.createElement("div");
    const st = (e.status || e.severity || "?").toLowerCase();
    let stCls = "ok";
    if (st === "warn" || st === "warning") stCls = "warn";
    else if (
      st === "error" ||
      st === "err" ||
      st === "fail" ||
      st === "failed" ||
      st === "down"
    )
      stCls = "err";
    else if (st === "info") stCls = "info";
    else if (st !== "ok") stCls = "err";

    line.className =
      "feed-line" +
      (isNew ? " new" : "") +
      (stCls === "warn" ? " feed-warn" : "") +
      (stCls === "err" ? " feed-err" : "");
    const ms =
      e.duration_ms != null && Number.isFinite(Number(e.duration_ms))
        ? `${Math.round(Number(e.duration_ms))}ms`
        : "—";
    const toolLabel = e.agent_id
      ? `${e.tool}`
      : e.tool || "?";
    const detail = e.detail || e.error || "—";
    line.innerHTML = `
      <span class="t">${esc(fmtTimeShort(e.timestamp))}</span>
      <span class="tool" title="${esc(e.kind || "")}">${esc(toolLabel)}</span>
      <span class="${stCls}">${esc((e.status || "?").slice(0, 6))}</span>
      <span class="ms">${esc(ms)}</span>
      <span class="detail" title="${esc(detail)}">${esc(detail)}</span>
    `;
    return line;
  }

  function render(data) {
    if (!data || typeof data !== "object") {
      setBoot("Invalid snapshot payload", "error");
      return;
    }
    if (data.error && !data.system) {
      setText("footer-meta", `error: ${data.error}`);
      setBoot(`API error: ${data.error}`, "error");
      return;
    }

    const sys = data.system || {};
    const forge = data.forge || {};
    const histIn = data.history || [];

    try {
    if (histIn.length && hist.t.length < 5) {
      for (const s of histIn) pushHist(s);
    } else if (sys.ts) {
      const g0 = (sys.gpu || [])[0] || {};
      const dio = sys.disk_io || {};
      pushHist({
        ts: sys.ts,
        cpu: (sys.cpu || {}).percent,
        gpu: g0.util_gpu,
        ram: (sys.ram || {}).pressure_percent ?? (sys.ram || {}).percent,
        disk: dio.total_mb_s,
        mcp_epm_5m: ((forge.mcp_load || {})["5m"] || {}).events_per_min,
      });
    }

    const cpu = sys.cpu || {};
    const ram = sys.ram || {};
    const g0 = (sys.gpu || [])[0] || {};
    const dio = sys.disk_io || {};
    const loadAvg = cpu.load_avg || {};

    setHtml("cpu-val", `${n(cpu.percent, 0).toFixed(0)}<small>%</small>`);
    setMeter("cpu-bar", cpu.percent);
    const threads =
      typeof cpu.count_logical === "number"
        ? cpu.count_logical
        : Array.isArray(cpu.per_cpu)
          ? cpu.per_cpu.length
          : "—";
    const brand = (cpu.brand || "").replace(/^Apple\s+/i, "");
    setText(
      "cpu-meta",
      `${threads} thr · load ${n(loadAvg.m1, 0).toFixed(2)} · ${brand || "CPU"}`
    );

    const freq = typeof cpu.freq_mhz === "number" && cpu.freq_mhz > 0 ? cpu.freq_mhz : 0;
    setHtml(
      "freq-val",
      freq ? `${Math.round(freq)}<small>MHz</small>` : `—<small>MHz</small>`
    );
    // Soft scale: treat ~4 GHz as full on desktop, 3.5 on Apple
    const freqCap = /apple|m[0-9]/i.test(String(cpu.brand || "")) ? 4500 : 5500;
    setMeter("freq-bar", freq ? (100 * freq) / freqCap : 0);
    setText(
      "freq-meta",
      `${cpu.count_physical || "—"} phys · user ${n(cpu.user, 0).toFixed(0)}% sys ${n(cpu.system, 0).toFixed(0)}%`
    );

    // Prefer pressure (available-based) on macOS unified memory
    const ramPct = n(ram.pressure_percent != null ? ram.pressure_percent : ram.percent, 0);
    setHtml("ram-val", `${ramPct.toFixed(0)}<small>%</small>`);
    setMeter("ram-bar", ramPct);
    setText(
      "ram-meta",
      `${n(ram.available_gb, 0).toFixed(1)} GB free · ${n(ram.total_gb, 0).toFixed(0)} GB` +
        (ram.swap_used_gb > 0 ? ` · swap ${n(ram.swap_used_gb, 0).toFixed(1)}` : "")
    );

    setHtml("gpu-val", `${n(g0.util_gpu, 0).toFixed(0)}<small>%</small>`);
    setMeter("gpu-bar", g0.util_gpu);
    if (g0.shared_memory || g0.metal || g0.vendor === "Apple") {
      const memUsed = n(g0.mem_used_mib, 0);
      const cores = g0.cores != null ? `${g0.cores}c` : "—";
      const r = g0.util_renderer != null ? ` R${Math.round(n(g0.util_renderer, 0))}` : "";
      const t = g0.util_tiler != null ? ` T${Math.round(n(g0.util_tiler, 0))}` : "";
      setText(
        "gpu-meta",
        `${(g0.name || "Apple GPU").replace(/^Apple\s+/, "")} · ${cores} · ${(memUsed / 1024).toFixed(1)} GB in-use${r}${t}`
      );
    } else {
      const memUsed = n(g0.mem_used_mib, 0);
      const memTotal = n(g0.mem_total_mib, 0);
      setText(
        "gpu-meta",
        `${(g0.name || "GPU").replace("NVIDIA GeForce ", "")} · ${Math.round(memUsed)}/${Math.round(memTotal)} MiB · ${g0.temp_c ?? "—"}°C`
      );
    }

    // Power card repurposed context: show SM clock if NVIDIA else disk already separate
    // Disk I/O strip card
    const totalMbs = n(dio.total_mb_s, 0);
    setHtml("disk-val", `${totalMbs.toFixed(1)}<small>MB/s</small>`);
    // Scale meter: 200 MB/s = full for local SSD activity feel
    setMeter("disk-bar", Math.min(100, (totalMbs / 200) * 100));
    setText(
      "disk-meta",
      `R ${n(dio.read_mb_s, 0).toFixed(1)} · W ${n(dio.write_mb_s, 0).toFixed(1)} · ${n(dio.total_iops, 0).toFixed(0)} IOPS`
    );

    renderCoreBars(cpu.per_cpu);
    setText(
      "cores-meta",
      `${Array.isArray(cpu.per_cpu) ? cpu.per_cpu.length : 0} CORES · AVG ${n(cpu.percent, 0).toFixed(1)}%`
    );
    renderDiskList(sys.disk || [], dio);
    const rootVol = (sys.disk || [])[0];
    setText(
      "storage-meta",
      rootVol
        ? `${rootVol.mount} ${n(rootVol.percent, 0).toFixed(0)}% USED`
        : "—"
    );

    renderOrchestration(forge.orchestration);
    renderProcesses(sys.processes || []);

    const load5 = (forge.mcp_load || {})["5m"] || {};
    const servers = forge.mcp_servers || [];
    const agents = forge.agents || [];
    const liveCount = servers.filter((s) => s.live).length;
    const activeAgents = agents.filter(
      (a) => a.live || a.status === "active" || a.status === "open"
    ).length;

    setText("pill-updated", `UPD ${fmtTimeShort(data.updated)}`);
    setText("pill-mcp", `MCP ${liveCount}/${servers.length}`);
    setText("pill-agents", `AGENTS ${activeAgents}`);
    setText(
      "pill-load",
      `LOAD ${load5.events_per_min ?? 0}/m · ERR ${load5.error_rate ?? 0}`
    );
    const pillLoad = $("pill-load");
    if (pillLoad) {
      if ((load5.error_rate || 0) > 0.25) pillLoad.className = "pill bad";
      else if ((load5.error_rate || 0) > 0.05) pillLoad.className = "pill warn";
      else pillLoad.className = "pill";
    }

    setText(
      "mcp-panel-meta",
      `${liveCount} LIVE · ${servers.length} TOTAL · ${load5.event_count ?? 0} EVT / 5M`
    );
    const mcpTools = forge.mcp_tools || [];
    const mcpPacks = forge.mcp_packs || [];
    const toolsActive = mcpTools.filter((t) => t.live || t.status === "active").length;
    const toolsWarm = mcpTools.filter((t) => t.status === "warm").length;
    setText(
      "tools-panel-meta",
      `${mcpTools.length} TOOLS · ${toolsActive} ACTIVE · ${toolsWarm} WARM · ${mcpPacks.length} PACKS`
    );
    const readyAgents = agents.filter(
      (a) => a.health === "ok" || a.health_label === "READY" || a.status === "ready"
    ).length;
    const warnAgents = agents.filter((a) => a.health === "warn").length;
    const errAgents = agents.filter(
      (a) => a.health === "error" || a.health === "down"
    ).length;
    setText(
      "agent-panel-meta",
      `${activeAgents} ACTIVE · ${readyAgents} READY · ${warnAgents} WARN · ${errAgents} ERR · ${agents.length} CATALOG`
    );
    const fs = forge.feed_stats || {};
    const feedLen = (forge.live_feed || []).length;
    setText(
      "feed-meta",
      `${feedLen} BUFFERED · WARN ${fs.warn ?? 0} · ERR ${fs.error ?? 0} · AGENT ${fs.agent_events ?? 0}`
    );

    renderMcpCards(servers);
    renderPackStrip(mcpPacks);
    renderToolCards(mcpTools);
    renderAgentCards(agents);
    renderFeed(forge.live_feed || []);

    setText(
      "footer-meta",
      `HOST ${sys.host || "—"} · ${sys.arch || ""} · HOME ${forge.home || "—"} · STORE ${forge.files?.store_sqlite ? "OK" : "—"} · AUDIT ${forge.files?.audit_jsonl ? "OK" : "—"}`
    );

    drawChart();
    lastOk = Date.now();
    setLive(true);
    const cpuPct = n((sys.cpu || {}).percent, 0).toFixed(0);
    const g0u = n(((sys.gpu || [])[0] || {}).util_gpu, 0).toFixed(0);
    setBoot(
      `Live · CPU ${cpuPct}% · GPU ${g0u}% · MCP ${(forge.mcp_servers || []).length} · ${location.origin}`,
      "ok"
    );
    } catch (err) {
      console.error("render failed", err);
      setBoot(`Render error: ${err && err.message ? err.message : err}`, "error");
    }
  }

  function setLive(ok) {
    const pill = $("pill-link");
    if (!pill) return;
    pill.classList.toggle("live", ok);
    pill.classList.toggle("bad", !ok);
    pill.innerHTML = ok
      ? `<span class="dot" id="dot"></span>LINK`
      : `<span class="dot off" id="dot"></span>RECONNECT`;
  }

  /** One-shot current frame (reconnect fallback only — not the product clock). */
  async function fetchLiveOnce() {
    try {
      const r = await fetch("/api/live", { cache: "no-store" });
      if (!r.ok) {
        // Compat for older builds
        const r2 = await fetch("/api/snapshot", { cache: "no-store" });
        if (!r2.ok) throw new Error(`HTTP ${r2.status}`);
        const data2 = await r2.json();
        render(data2);
        return true;
      }
      const data = await r.json();
      render(data);
      return true;
    } catch (e) {
      console.warn("live frame fetch failed", e);
      if (Date.now() - lastOk > 5000) {
        setLive(false);
        setBoot(
          `Cannot reach API (${e && e.message ? e.message : e}). Try http://127.0.0.1:7788/ — not https.`,
          "error"
        );
      }
      return false;
    }
  }

  /** Slow safety net only when the realtime stream is silent. */
  function startFallbackWatchdog() {
    if (pollTimer) return;
    const tick = async () => {
      if (Date.now() - lastOk > 2500) {
        await fetchLiveOnce();
      }
      pollTimer = setTimeout(tick, 2000);
    };
    tick();
  }

  function connectSse() {
    if (!window.EventSource) {
      setBoot("EventSource unavailable — using /api/live fallback", "error");
      startFallbackWatchdog();
      return;
    }
    if (es) {
      try {
        es.close();
      } catch {
        /* ignore */
      }
      es = null;
    }
    try {
      // Continuous realtime SSE (~20 Hz). Legacy interval=2 is ignored server-side.
      es = new EventSource("/api/stream?hz=20");
    } catch (e) {
      console.warn("EventSource unavailable", e);
      startFallbackWatchdog();
      return;
    }
    es.onopen = () => {
      setLive(true);
      setBoot("Realtime stream connected", "ok");
    };
    es.onerror = () => {
      try {
        es.close();
      } catch {
        /* ignore */
      }
      es = null;
      setLive(false);
      setBoot("Realtime stream reconnecting…", "");
      setTimeout(connectSse, 1500);
    };
    const onFrame = (ev) => {
      try {
        render(JSON.parse(ev.data));
      } catch (e) {
        console.error("SSE", e);
      }
    };
    es.onmessage = onFrame;
    es.addEventListener("telemetry", onFrame);
  }

  window.addEventListener("error", (ev) => {
    setBoot(`JS error: ${ev.message || "unknown"}`, "error");
  });
  window.addEventListener("unhandledrejection", (ev) => {
    const m = ev.reason && (ev.reason.message || String(ev.reason));
    setBoot(`Promise error: ${m || "unknown"}`, "error");
  });

  window.addEventListener("resize", drawChart);
  setText("origin", location.origin || "local");
  // Product path: continuous SSE first; one frame seed; watchdog only if stream stalls.
  fetchLiveOnce();
  connectSse();
  startFallbackWatchdog();
})();

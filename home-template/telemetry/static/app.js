/* Forge Rig Telemetry — Tron UI: stack control, MCP cards, agents, live feed */
(() => {
  const $ = (id) => document.getElementById(id);
  const hist = { t: [], cpu: [], gpu: [], ram: [], epm: [] };
  const MAX = 90;
  let lastOk = 0;
  let es = null;
  let pollTimer = null;
  let seenFeed = new Set();
  let feedPrimed = false;
  let stackBusy = false;
  let lastStack = null;

  async function stackApi(path, method = "GET") {
    try {
      const r = await fetch(path, {
        method,
        cache: "no-store",
        headers: method === "POST" ? { "Content-Type": "application/json" } : undefined,
        body: method === "POST" ? "{}" : undefined,
      });
      const text = await r.text();
      try {
        const j = JSON.parse(text);
        if (!r.ok && j.ok !== true) j.ok = false;
        j._http = r.status;
        return j;
      } catch {
        return { ok: false, error: `bad JSON HTTP ${r.status}: ${text.slice(0, 200)}` };
      }
    } catch (e) {
      return { ok: false, error: String(e) };
    }
  }

  function renderStack(status) {
    lastStack = status;
    const consoleEl = $("stack-console");
    const stateEl = $("stack-state");
    const metaEl = $("stack-meta");
    const rolesEl = $("stack-roles");
    if (!consoleEl || !stateEl) return;

    const desired = (status && status.desired) || "unloaded";
    const roles = (status && status.roles) || {};
    const liveRoles = Object.entries(roles).filter(([, v]) => v).length;
    const totalRoles = Math.max(3, Object.keys(roles).length || 3);
    const fullyLoaded = !!(status && status.loaded);
    const partial = !!(status && status.partially_loaded) || (desired === "loaded" && liveRoles > 0 && liveRoles < totalRoles);
    const loading = desired === "loaded" && !fullyLoaded && !partial && liveRoles === 0;
    const unloading = desired === "unloaded" && liveRoles > 0;

    consoleEl.classList.toggle("is-loaded", fullyLoaded);
    consoleEl.classList.toggle("is-unloaded", desired === "unloaded" && liveRoles === 0);
    consoleEl.classList.toggle("is-partial", !!partial || !!loading || !!unloading);
    // Never lock the whole console — only dim while a POST is in flight briefly
    consoleEl.classList.toggle("is-busy", stackBusy);

    // Prefer server truth over sticky "WORKING"
    if (fullyLoaded) stateEl.textContent = "LOADED";
    else if (partial) stateEl.textContent = "PARTIAL";
    else if (loading || (stackBusy && desired !== "unloaded")) stateEl.textContent = "LOADING";
    else if (unloading) stateEl.textContent = "STOPPING";
    else stateEl.textContent = "UNLOADED";

    if (rolesEl) {
      rolesEl.innerHTML = "";
      const order = ["memory", "primary", "fallback"];
      const keys = order.concat(Object.keys(roles).filter((k) => !order.includes(k)));
      keys.forEach((k) => {
        const on = !!(roles[k]);
        const span = document.createElement("span");
        span.className = "stack-role " + (on ? "on" : "off");
        span.textContent = `${k.toUpperCase()} ${on ? "ON" : "OFF"}`;
        rolesEl.appendChild(span);
      });
    }

    const rd = (status && status.ramdisk) || {};
    const ramEl = $("stack-ram");
    if (ramEl) {
      if (rd.mounted) {
        ramEl.textContent = `RAM ${rd.letter}: · ${rd.size_gb_config || "?"}GB · snap ${rd.last_snapshot_ok ? "OK" : "—"}`;
        ramEl.classList.add("on");
        ramEl.classList.remove("off");
      } else {
        ramEl.textContent = `RAM DISK OFF · cfg ${rd.size_gb_config || 16}–${rd.size_gb_max || 32}GB`;
        ramEl.classList.add("off");
        ramEl.classList.remove("on");
      }
    }

    if (metaEl && !stackBusy) {
      const bits = [
        `desired=${desired}`,
        `live ${liveRoles}/${totalRoles}`,
        `procs=${status?.process_count ?? "—"}`,
        status?.mode || "ramdisk-on-demand",
        rd.mounted ? `vol=${rd.letter}:` : "vol=off",
        status?.restart_policy || "failure-only while loaded",
      ];
      metaEl.textContent = bits.join(" · ");
    }

    // Re-enable buttons from server state
    ["btn-stack-load", "btn-stack-unload", "btn-stack-restart", "btn-stack-snapshot", "btn-stack-warm"].forEach((id) => {
      const b = $(id);
      if (b) b.disabled = !!stackBusy;
    });
  }

  async function refreshStack() {
    try {
      const s = await stackApi("/api/stack");
      // If server says unloaded/loaded clearly, drop sticky busy
      if (s && (s.loaded || s.desired === "unloaded")) {
        // allow busy only during explicit action window
      }
      renderStack(s);
      return s;
    } catch (e) {
      renderStack({ desired: "unloaded", roles: {}, process_count: 0, loaded: false });
      return null;
    }
  }

  async function stackAction(kind) {
    if (stackBusy) return;
    stackBusy = true;
    const metaEl = $("stack-meta");
    const labels = {
      load: "Creating RAM disk + hydrating package… (may take a few minutes)",
      unload: "Snapshot + stopping keepers + destroying RAM disk…",
      restart: "Recycling RAM stack (unload → load)…",
      snapshot: "Writing durable snapshot…",
      warm: "Warming process-RAM corpora…",
    };
    if (metaEl) metaEl.textContent = labels[kind] || `${kind}…`;
    renderStack(lastStack || { desired: kind === "load" || kind === "restart" ? "loaded" : "unloaded", roles: {} });

    let finished = false;
    try {
      const pathMap = {
        load: "/api/stack/load",
        unload: "/api/stack/unload",
        restart: "/api/stack/restart",
        snapshot: "/api/stack/snapshot",
        warm: "/api/stack/warm",
      };
      const path = pathMap[kind] || "/api/stack/warm";
      const r = await stackApi(path, "POST");
      console.log("stackAction", kind, r);
      if (!r || r.ok === false) {
        if (metaEl) metaEl.textContent = `${kind} failed: ${(r && r.error) || "see logs"}`;
        return;
      }
      if (metaEl) metaEl.textContent = `${kind} started (pid ${r.pid || "—"}) — waiting…`;
      // LOAD/RESTART hydrate 16GB image — allow longer poll window
      const maxWait =
        kind === "load" || kind === "restart" ? 600_000 : kind === "unload" ? 180_000 : 60_000;
      const deadline = Date.now() + maxWait;
      while (Date.now() < deadline) {
        await new Promise((res) => setTimeout(res, 1000));
        const s = await refreshStack();
        if (kind === "warm" || kind === "snapshot") {
          finished = true;
          break;
        }
        if ((kind === "load" || kind === "restart") && s && (s.loaded || s.partially_loaded)) {
          finished = true;
          break;
        }
        if (
          kind === "unload" &&
          s &&
          s.desired === "unloaded" &&
          !s.loaded &&
          (s.process_count || 0) === 0 &&
          !(s.ramdisk && s.ramdisk.mounted)
        ) {
          finished = true;
          break;
        }
      }
      if (metaEl) {
        const s = lastStack;
        metaEl.textContent = finished
          ? `${kind} done · ${s?.loaded ? "LOADED" : s?.desired || ""} · ram=${s?.ramdisk?.mounted ? s.ramdisk.letter + ":" : "off"}`
          : `${kind} timeout — desired=${s?.desired} loaded=${s?.loaded} ram=${s?.ramdisk?.mounted} (check logs\\stack-control.log)`;
      }
    } catch (e) {
      if (metaEl) metaEl.textContent = `${kind} error: ${e}`;
      console.error(e);
    } finally {
      stackBusy = false;
      await refreshStack();
    }
  }

  function wireStackButtons() {
    const map = {
      "btn-stack-load": "load",
      "btn-stack-unload": "unload",
      "btn-stack-restart": "restart",
      "btn-stack-snapshot": "snapshot",
      "btn-stack-warm": "warm",
    };
    Object.entries(map).forEach(([id, kind]) => {
      const el = $(id);
      if (el) el.addEventListener("click", () => stackAction(kind));
    });
    refreshStack();
    setInterval(refreshStack, 5000);
    wireBackendButtons();
    refreshBackend();
    setInterval(refreshBackend, 5000);
  }

  async function refreshBackend() {
    try {
      const s = await stackApi("/api/agent-backend");
      const stateEl = $("backend-state");
      const metaEl = $("backend-meta");
      const workerEl = $("backend-worker");
      const consoleEl = $("backend-console");
      if (!stateEl) return;
      const mode = (s && s.mode) || "host";
      const gen = s && s.generation != null ? s.generation : "—";
      stateEl.textContent = mode === "grok" ? "GROK BUILD" : "HOST";
      if (consoleEl) {
        consoleEl.classList.toggle("is-loaded", mode === "grok");
        consoleEl.classList.toggle("is-unloaded", mode === "host");
      }
      if (metaEl) {
        const pol = (s && s.policy && s.policy.policy) || "";
        metaEl.textContent =
          mode === "grok"
            ? `mode=grok · gen=${gen} · ${pol} · paste connect prompt into Grok Build · new LM Studio chat for Qwen`
            : `mode=host · gen=${gen} · local Qwen runs agents`;
      }
      if (workerEl) {
        const w = (s && s.worker) || {};
        const alive = !!(w.grok_build_attached || w.worker_alive);
        workerEl.textContent = alive
          ? "GROK BUILD ATTACHED"
          : mode === "grok"
            ? "AWAITING GROK BUILD (paste prompt)"
            : "GROK BUILD OFF";
        workerEl.classList.toggle("on", alive);
        workerEl.classList.toggle("off", !alive);
      }
      window.__lastBackend = s;
    } catch (e) {
      const metaEl = $("backend-meta");
      if (metaEl) metaEl.textContent = `backend status error: ${e}`;
    }
  }

  function showConnectModal(text) {
    const modal = $("connect-modal");
    const ta = $("connect-prompt-text");
    const st = $("connect-copy-status");
    if (!modal || !ta) return;
    ta.value = text || "(no prompt — try PROMPT button or re-click GROK)";
    if (st) st.textContent = "";
    modal.hidden = false;
  }

  function hideConnectModal() {
    const modal = $("connect-modal");
    if (modal) modal.hidden = true;
  }

  async function copyConnectPrompt() {
    const ta = $("connect-prompt-text");
    const st = $("connect-copy-status");
    if (!ta) return;
    try {
      ta.select();
      await navigator.clipboard.writeText(ta.value);
      if (st) st.textContent = "Copied — paste into Grok Build.";
    } catch (e) {
      try {
        document.execCommand("copy");
        if (st) st.textContent = "Copied (fallback).";
      } catch (e2) {
        if (st) st.textContent = "Select all and copy manually (Ctrl+C).";
      }
    }
  }

  async function fetchConnectPrompt() {
    try {
      const r = await fetch("/api/agent-backend/connect-prompt", { cache: "no-store" });
      const j = await r.json();
      return (j && (j.prompt || j.connect_prompt || j.text)) || "";
    } catch {
      return (window.__lastBackend && window.__lastBackend.connect_prompt) || "";
    }
  }

  async function setBackend(mode) {
    const metaEl = $("backend-meta");
    if (metaEl) metaEl.textContent = `Switching agent backend to ${mode}…`;
    try {
      const res = await fetch("/api/agent-backend", {
        method: "POST",
        cache: "no-store",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mode, reason: "dashboard", notify: true }),
      });
      const text = await res.text();
      let j = {};
      try {
        j = JSON.parse(text);
      } catch {
        j = { ok: false, error: text.slice(0, 200) };
      }
      console.log("setBackend", j);
      if (metaEl) {
        metaEl.textContent =
          j.ok !== false && (j.mode || j.generation != null)
            ? `mode=${j.mode} gen=${j.generation}`
            : `failed: ${j.error || res.status}`;
      }
      if (mode === "grok") {
        const prompt =
          (j.connect_prompt && (j.connect_prompt.text || j.connect_prompt)) ||
          j.connect_prompt_text ||
          (await fetchConnectPrompt());
        showConnectModal(typeof prompt === "string" ? prompt : JSON.stringify(prompt, null, 2));
      }
    } catch (e) {
      if (metaEl) metaEl.textContent = `set error: ${e}`;
    }
    await refreshBackend();
  }

  function wireBackendButtons() {
    const host = $("btn-backend-host");
    const grok = $("btn-backend-grok");
    const promptBtn = $("btn-backend-prompt");
    if (host) host.addEventListener("click", () => setBackend("host"));
    if (grok) grok.addEventListener("click", () => setBackend("grok"));
    if (promptBtn) {
      promptBtn.addEventListener("click", async () => {
        const t = await fetchConnectPrompt();
        showConnectModal(t || "Switch to GROK first to generate the prompt.");
      });
    }
    const close = $("connect-modal-close");
    const done = $("connect-modal-done");
    const copy = $("connect-copy");
    if (close) close.addEventListener("click", hideConnectModal);
    if (done) done.addEventListener("click", hideConnectModal);
    if (copy) copy.addEventListener("click", copyConnectPrompt);
    const overlay = $("connect-modal");
    if (overlay) {
      overlay.addEventListener("click", (ev) => {
        if (ev.target === overlay) hideConnectModal();
      });
    }
  }

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
    // HH:MM:SS preference
    const m = String(s).match(/(\d{1,2}:\d{2}:\d{2})/);
    return m ? m[1] : s;
  }

  function pushHist(snap) {
    hist.t.push(snap.ts || Date.now() / 1000);
    hist.cpu.push(snap.cpu != null ? n(snap.cpu, null) : null);
    hist.gpu.push(snap.gpu != null ? n(snap.gpu, null) : null);
    hist.ram.push(snap.ram != null ? n(snap.ram, null) : null);
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
      { key: "epm", color: "#ff6a1a", max: null },
    ];
    const epmVals = hist.epm.filter((x) => x != null && Number.isFinite(x));
    const epmMax = Math.max(5, ...(epmVals.length ? epmVals : [1]), 1);

    for (const s of series) {
      const arr = hist[s.key];
      const max = s.max ?? epmMax;
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
    const map = {
      ok: { cls: "health-ok", text: "READY" },
      ready: { cls: "health-ok", text: "READY" },
      error: { cls: "health-error", text: "ERROR" },
      down: { cls: "health-error", text: "DOWN" },
      warn: { cls: "health-warn", text: "WARN" },
      warning: { cls: "health-warn", text: "WARN" },
      config: { cls: "health-config", text: "CONFIG" },
    };
    const m = map[h] || map.ok;
    // Prefer explicit health_label from API when present
    const text = fallbackLabel || m.text;
    return { cls: `ec-role ${m.cls}`, text };
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
        s.role === "memory" ? "role-memory" : "",
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
      const titleName = s.display || s.label;
      card.title = `${titleName} · ${s.label} · ${s.role} · ${s.health_label || health} · ${s.health_reason || ""} · ${s.description || ""}`;
      card.innerHTML = `
        <div class="ec-top">
          <div class="ec-name">${esc(titleName)}<span class="ec-sublabel">${esc(s.label)}</span></div>
          <div class="${badge.cls}" title="${esc(s.health_reason || badge.text)}">${esc(badge.text)}</div>
        </div>
        <div class="ec-status health-${esc(health)}">${esc(s.role || "mcp")} · ${esc(s.status)}${s.live ? " · LINK" : s.registered ? " · REG" : ""}</div>
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
        <div class="ec-tools">${tools || `<span>${s.live ? "idle" : "offline"}</span>`}</div>
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

  /** shell_exec → SHELL, fs_write → FS, agent_session_start → AGENT */
  function shortToolLabel(tool) {
    const parts = String(tool || "")
      .split(/[_\s]+/)
      .filter(Boolean);
    if (!parts.length) return "?";
    return parts[0].toUpperCase();
  }

  /** Map activity 0–100 → load tier for card color (not problem colors). */
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
    // Prefer showing live/open first; still show catalog
    const list = agents || [];
    if (!list.length) {
      root.innerHTML = `<div class="empty-hint">NO AGENTS REGISTERED</div>`;
      return;
    }
    // Show all with sessions or activity first; cap idle to keep grid readable
    const hot = list.filter((a) => a.live || a.status !== "idle" || (a.activity || 0) > 0);
    const idle = list.filter((a) => !hot.includes(a));
    const show = [...hot, ...idle].slice(0, 16);

    for (const a of show) {
      const cls = [
        "entity-card",
        a.live ? "live" : "",
        a.status === "active" || a.status === "open" ? "active" : "",
        a.status === "idle" ? "idle" : "",
      ]
        .filter(Boolean)
        .join(" ");
      const u = a.usage_15m || {};
      const sess = (a.sessions || []).length;
      const card = document.createElement("div");
      card.className = cls;
      card.innerHTML = `
        <div class="ec-top">
          <div class="ec-name">${esc(a.agent_id)}</div>
        </div>
        <div class="ec-status ${esc(a.status)}">${esc(a.status)}</div>
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
      // oldest first for natural scroll-down log feel
      const chronological = [...list].reverse();
      for (const e of chronological) {
        seenFeed.add(e.id);
        root.appendChild(makeFeedLine(e, false));
      }
      feedPrimed = true;
      root.scrollTop = root.scrollHeight;
      return;
    }

    // Newest events first in API; append new ones
    const newestFirst = list;
    const toAdd = [];
    for (const e of newestFirst) {
      if (seenFeed.has(e.id)) break;
      toAdd.push(e);
    }
    toAdd.reverse();
    for (const e of toAdd) {
      seenFeed.add(e.id);
      const line = makeFeedLine(e, true);
      root.appendChild(line);
    }
    // Cap DOM nodes
    while (root.children.length > 100) {
      const first = root.firstElementChild;
      if (first) root.removeChild(first);
    }
    if (toAdd.length) {
      root.scrollTop = root.scrollHeight;
    }
  }

  function makeFeedLine(e, isNew) {
    const line = document.createElement("div");
    line.className = "feed-line" + (isNew ? " new" : "");
    const st = (e.status || "").toLowerCase();
    const stCls = st === "ok" ? "ok" : "err";
    const ms =
      e.duration_ms != null && Number.isFinite(Number(e.duration_ms))
        ? `${Math.round(Number(e.duration_ms))}ms`
        : "—";
    line.innerHTML = `
      <span class="t">${esc(fmtTimeShort(e.timestamp))}</span>
      <span class="tool">${esc(e.tool)}</span>
      <span class="${stCls}">${esc((e.status || "?").slice(0, 6))}</span>
      <span class="ms">${esc(ms)}</span>
      <span class="detail" title="${esc(e.detail || e.error || "")}">${esc(e.detail || e.error || "—")}</span>
    `;
    return line;
  }

  function render(data) {
    if (!data || typeof data !== "object") return;
    if (data.error && !data.system) {
      setText("footer-meta", `error: ${data.error}`);
      return;
    }

    const sys = data.system || {};
    const forge = data.forge || {};
    const histIn = data.history || [];

    if (histIn.length && hist.t.length < 5) {
      for (const s of histIn) pushHist(s);
    } else if (sys.ts) {
      const g0 = (sys.gpu || [])[0] || {};
      pushHist({
        ts: sys.ts,
        cpu: (sys.cpu || {}).percent,
        gpu: g0.util_gpu,
        ram: (sys.ram || {}).percent,
        mcp_epm_5m: ((forge.mcp_load || {})["5m"] || {}).events_per_min,
      });
    }

    const cpu = sys.cpu || {};
    const ram = sys.ram || {};
    const g0 = (sys.gpu || [])[0] || {};

    setHtml("cpu-val", `${n(cpu.percent, 0).toFixed(0)}<small>%</small>`);
    setMeter("cpu-bar", cpu.percent);
    const threads =
      typeof cpu.count_logical === "number"
        ? cpu.count_logical
        : Array.isArray(cpu.per_cpu)
          ? cpu.per_cpu.length
          : "—";
    const freq =
      typeof cpu.freq_mhz === "number" && cpu.freq_mhz > 0
        ? `${Math.round(cpu.freq_mhz)} MHz`
        : "—";
    setText("cpu-meta", `${threads} thr · ${freq}`);

    setHtml("ram-val", `${n(ram.percent, 0).toFixed(0)}<small>%</small>`);
    setMeter("ram-bar", ram.percent);
    setText(
      "ram-meta",
      `${n(ram.used_gb, 0).toFixed(0)}/${n(ram.total_gb, 0).toFixed(0)} GB`
    );

    setHtml("gpu-val", `${n(g0.util_gpu, 0).toFixed(0)}<small>%</small>`);
    setMeter("gpu-bar", g0.util_gpu);
    const memUsed = n(g0.mem_used_mib, 0);
    const memTotal = n(g0.mem_total_mib, 0);
    setText(
      "gpu-meta",
      `${(g0.name || "GPU").replace("NVIDIA GeForce ", "")} · ${Math.round(memUsed)}/${Math.round(memTotal)} MiB · ${g0.temp_c ?? "—"}°C`
    );

    const pwr = n(g0.power_w, 0);
    const plim = n(g0.power_limit_w, 450) || 450;
    setHtml("pwr-val", `${pwr.toFixed(0)}<small>W</small>`);
    setMeter("pwr-bar", (100 * pwr) / plim);
    setText("pwr-meta", `limit ${plim.toFixed(0)} W · SM ${Math.round(n(g0.clock_sm_mhz, 0))}`);

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
    setText(
      "agent-panel-meta",
      `${activeAgents} ACTIVE · ${agents.length} IN CATALOG`
    );
    setText("feed-meta", `${(forge.live_feed || []).length} BUFFERED`);

    renderMcpCards(servers);
    renderPackStrip(mcpPacks);
    renderToolCards(mcpTools);
    renderAgentCards(agents);
    renderFeed(forge.live_feed || []);

    setText(
      "footer-meta",
      `HOME ${forge.home || "—"} · STORE ${forge.files?.store_sqlite ? "OK" : "—"} · AUDIT ${forge.files?.audit_jsonl ? "OK" : "—"} · LAN OPEN`
    );

    drawChart();
    lastOk = Date.now();
    setLive(true);
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

  async function pollOnce() {
    try {
      const r = await fetch("/api/snapshot", { cache: "no-store" });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      render(await r.json());
      return true;
    } catch (e) {
      console.warn("poll failed", e);
      if (Date.now() - lastOk > 5000) setLive(false);
      return false;
    }
  }

  function startPoll() {
    if (pollTimer) return;
    const tick = async () => {
      await pollOnce();
      pollTimer = setTimeout(tick, 2000);
    };
    tick();
  }

  function connectSse() {
    if (!window.EventSource) return;
    if (es) {
      try {
        es.close();
      } catch {
        /* ignore */
      }
      es = null;
    }
    es = new EventSource("/api/stream?interval=2");
    es.onopen = () => setLive(true);
    es.onerror = () => {
      setLive(false);
      try {
        es.close();
      } catch {
        /* ignore */
      }
      es = null;
      setTimeout(connectSse, 3000);
    };
    es.onmessage = (ev) => {
      try {
        render(JSON.parse(ev.data));
      } catch (e) {
        console.error("SSE", e);
      }
    };
  }

  window.addEventListener("resize", drawChart);
  setText("origin", location.origin);
  wireStackButtons();
  startPoll();
  connectSse();
})();

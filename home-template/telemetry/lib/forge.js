/**
 * Read-only Forge-Conductor telemetry from home store + audit log.
 * Never opens SQLite read-write. Never attaches to MCP stdio.
 */
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { DatabaseSync } from "node:sqlite";
import { TOOL_PACKS, allToolsFlat, packForTool } from "./tools-catalog.js";

/** Built-in + common home agent ids (for idle cards). */
const KNOWN_AGENTS = [
  "explore",
  "plan",
  "implement",
  "review",
  "debug",
  "test",
  "research",
  "docs",
  "refactor",
  "security",
  "release",
  "precommit-audit",
];

export function forgeHome() {
  return (
    process.env.FORGE_CONDUCTOR_HOME ||
    path.join(os.homedir(), ".forge-conductor")
  );
}

function openRo() {
  const dbPath = path.join(forgeHome(), "store.sqlite");
  if (!fs.existsSync(dbPath)) return null;
  try {
    return new DatabaseSync(dbPath, { readOnly: true });
  } catch {
    return null;
  }
}

function tableExists(db, name) {
  try {
    const row = db
      .prepare("SELECT 1 AS ok FROM sqlite_master WHERE type='table' AND name=?")
      .get(name);
    return Boolean(row);
  } catch {
    return false;
  }
}

function rows(db, sql, ...params) {
  try {
    return db.prepare(sql).all(...params);
  } catch {
    return [];
  }
}

export function collectPresence() {
  const db = openRo();
  if (!db) return [];
  try {
    if (!tableExists(db, "presence")) return [];
    return rows(
      db,
      "SELECT client_id, host_kind, pid, cwd, last_heartbeat FROM presence ORDER BY last_heartbeat DESC LIMIT 50"
    );
  } finally {
    try {
      db.close();
    } catch {
      /* ignore */
    }
  }
}

export function collectAgentSessions(limit = 40) {
  const db = openRo();
  if (!db) return [];
  try {
    if (!tableExists(db, "agent_sessions")) return [];
    return rows(
      db,
      "SELECT id, agent_id, client_id, status, summary, created_at, updated_at FROM agent_sessions ORDER BY updated_at DESC LIMIT ?",
      limit
    );
  } finally {
    try {
      db.close();
    } catch {
      /* ignore */
    }
  }
}

export function collectJobs(limit = 30) {
  const db = openRo();
  if (!db) return [];
  try {
    if (!tableExists(db, "jobs")) return [];
    return rows(
      db,
      "SELECT id, type, status, owner_client_id, created_at, updated_at FROM jobs ORDER BY updated_at DESC LIMIT ?",
      limit
    );
  } finally {
    try {
      db.close();
    } catch {
      /* ignore */
    }
  }
}

export function collectAuditSql(limit = 80) {
  const db = openRo();
  if (!db) return [];
  try {
    if (!tableExists(db, "audit_events")) return [];
    return rows(
      db,
      "SELECT id, timestamp, client_id, tool, status, duration_ms, error, args_json FROM audit_events ORDER BY id DESC LIMIT ?",
      limit
    );
  } finally {
    try {
      db.close();
    } catch {
      /* ignore */
    }
  }
}

export function collectAuditJsonl(limit = 100) {
  const p = path.join(forgeHome(), "audit.jsonl");
  if (!fs.existsSync(p)) return [];
  try {
    let buf = fs.readFileSync(p);
    if (buf.length > 2_000_000) buf = buf.subarray(buf.length - 2_000_000);
    const text = buf.toString("utf8");
    const lines = text.split(/\r?\n/).filter((ln) => ln.trim());
    const out = [];
    for (const ln of lines.slice(-limit)) {
      try {
        out.push(JSON.parse(ln));
      } catch {
        /* skip */
      }
    }
    out.reverse();
    return out;
  } catch {
    return [];
  }
}

function parseTs(ts) {
  if (typeof ts === "number" && Number.isFinite(ts)) return ts;
  if (typeof ts === "string" && ts.includes("T")) {
    const t = Date.parse(ts);
    return Number.isFinite(t) ? t / 1000 : null;
  }
  return null;
}

export function summarizeTools(events, windowSec = 3600) {
  const now = Date.now() / 1000;
  const recent = [];
  for (const e of events) {
    const t = parseTs(e.timestamp ?? e.ts);
    if (t == null || now - t <= windowSec) recent.push(e);
  }

  const tools = new Map();
  const status = new Map();
  let errors = 0;
  const durations = [];
  for (const e of recent) {
    const tool = e.tool || "unknown";
    tools.set(tool, (tools.get(tool) || 0) + 1);
    const st = e.status || "unknown";
    status.set(st, (status.get(st) || 0) + 1);
    if (st !== "ok") errors += 1;
    if (typeof e.duration_ms === "number") durations.push(e.duration_ms);
  }

  const topTools = [...tools.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15);
  const spanMin = Math.max(windowSec / 60, 1);
  durations.sort((a, b) => a - b);
  return {
    window_sec: windowSec,
    event_count: recent.length,
    events_per_min: Math.round((recent.length / spanMin) * 100) / 100,
    error_count: errors,
    error_rate: Math.round((errors / Math.max(recent.length, 1)) * 1000) / 1000,
    top_tools: topTools,
    by_status: Object.fromEntries(status),
    duration_ms_avg: durations.length
      ? Math.round((durations.reduce((a, b) => a + b, 0) / durations.length) * 10) / 10
      : null,
    duration_ms_p95: durations.length
      ? Math.round(
          durations[Math.min(durations.length - 1, Math.floor(durations.length * 0.95))] * 10
        ) / 10
      : null,
  };
}

export function summarizeAgents(sessions) {
  const byAgent = new Map();
  const byStatus = new Map();
  let active = 0;
  for (const s of sessions) {
    const a = s.agent_id || "?";
    byAgent.set(a, (byAgent.get(a) || 0) + 1);
    const st = s.status || "?";
    byStatus.set(st, (byStatus.get(st) || 0) + 1);
    if (["active", "running", "open", "started"].includes(st)) active += 1;
  }
  return {
    session_count: sessions.length,
    active_ish: active,
    by_agent: [...byAgent.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20),
    by_status: Object.fromEntries(byStatus),
  };
}

/** Always-visible forge-family MCP servers (LM Studio + dashboard). */
const FORGE_FAMILY = [
  {
    label: "ram-memory",
    role: "memory",
    display: "RAM Memory",
    description: "Full memory corpus in RAM · disk backup",
  },
  {
    label: "forge-conductor",
    role: "primary",
    display: "Forge Conductor",
    description: "Primary orchestration MCP",
  },
  {
    label: "forge-conductor-fallback",
    role: "fallback",
    display: "Forge Fallback",
    description: "Spare conductor (auto fail-over)",
  },
];

function mcpLabelFromPresence(p) {
  const hk = String(p?.host_kind || "").toLowerCase();
  const cwd = String(p?.cwd || "").replace(/\\/g, "/").toLowerCase();
  // Prefer explicit host_kind tags written by launchers
  if (
    hk.includes("ram-memory") ||
    hk.endsWith("/memory") ||
    hk === "memory" ||
    cwd.includes("mcp-role/memory") ||
    cwd.includes("ram-memory")
  ) {
    return "ram-memory";
  }
  if (
    hk.includes("fallback") ||
    cwd.includes("mcp-role/fallback") ||
    cwd.includes("fallback")
  ) {
    return "forge-conductor-fallback";
  }
  if (
    hk.includes("primary") ||
    cwd.includes("mcp-role/primary") ||
    cwd.includes("forge-conductor")
  ) {
    return "forge-conductor";
  }
  // Legacy: bare "mcp" → primary
  if (hk === "mcp" || hk.startsWith("mcp")) {
    return "forge-conductor";
  }
  const base = cwd.split("/").filter(Boolean).pop() || "mcp";
  if (base.includes("fallback")) return "forge-conductor-fallback";
  if (base.includes("memory")) return "ram-memory";
  return base.includes("forge") ? "forge-conductor" : base;
}

function roleFromLabel(label) {
  if (label === "ram-memory" || label.includes("memory")) return "memory";
  if (label.includes("fallback")) return "fallback";
  if (label === "forge-conductor") return "primary";
  return "mcp";
}

function readRegisteredMcpServers() {
  /** Keys from ~/.lmstudio/mcp.json (forge family + any extras). */
  try {
    const mcpPath = path.join(os.homedir(), ".lmstudio", "mcp.json");
    if (!fs.existsSync(mcpPath)) return FORGE_FAMILY.map((f) => f.label);
    const data = JSON.parse(fs.readFileSync(mcpPath, "utf8"));
    const keys = Object.keys(data?.mcpServers || {});
    return keys.length ? keys : FORGE_FAMILY.map((f) => f.label);
  } catch {
    return FORGE_FAMILY.map((f) => f.label);
  }
}

function emptyUsage() {
  return {
    event_count: 0,
    events_per_min: 0,
    error_count: 0,
    error_rate: 0,
    top_tools: [],
    last_tool: null,
    last_status: null,
    last_ts: null,
  };
}

/** Attribute audit events to ram-memory when tools are memory-family (no client). */
function usageForMemoryPack(events, windowSec = 900) {
  const memTools = new Set([
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
  ]);
  const filtered = windowEvents(events, windowSec).filter((e) =>
    memTools.has(e.tool || "")
  );
  const tools = new Map();
  let errors = 0;
  let last = null;
  for (const e of filtered) {
    tools.set(e.tool || "?", (tools.get(e.tool || "?") || 0) + 1);
    if ((e.status || "") !== "ok") errors += 1;
    if (!last) last = e;
  }
  const spanMin = Math.max(windowSec / 60, 1);
  return {
    event_count: filtered.length,
    events_per_min: Math.round((filtered.length / spanMin) * 100) / 100,
    error_count: errors,
    error_rate: Math.round((errors / Math.max(filtered.length, 1)) * 1000) / 1000,
    top_tools: [...tools.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5),
    last_tool: last?.tool || null,
    last_status: last?.status || null,
    last_ts: last?.timestamp || null,
  };
}

function windowEvents(events, windowSec) {
  const now = Date.now() / 1000;
  return events.filter((e) => {
    const t = parseTs(e.timestamp ?? e.ts);
    return t == null || now - t <= windowSec;
  });
}

function usageForClient(events, clientId, windowSec = 900) {
  const filtered = windowEvents(events, windowSec).filter(
    (e) => !clientId || e.client_id === clientId
  );
  const tools = new Map();
  let errors = 0;
  let last = null;
  for (const e of filtered) {
    tools.set(e.tool || "?", (tools.get(e.tool || "?") || 0) + 1);
    if ((e.status || "") !== "ok") errors += 1;
    if (!last) last = e;
  }
  const spanMin = Math.max(windowSec / 60, 1);
  return {
    event_count: filtered.length,
    events_per_min: Math.round((filtered.length / spanMin) * 100) / 100,
    error_count: errors,
    error_rate: Math.round((errors / Math.max(filtered.length, 1)) * 1000) / 1000,
    top_tools: [...tools.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5),
    last_tool: last?.tool || null,
    last_status: last?.status || null,
    last_ts: last?.timestamp || null,
  };
}

function heartbeatAgeSec(hb) {
  const t = parseTs(hb);
  if (t == null) return null;
  return Math.max(0, Math.round(Date.now() / 1000 - t));
}

function isLive(ageSec, ttl = 45) {
  return ageSec != null && ageSec <= ttl;
}

/** Memory keeper may use longer presence TTL; allow 120s before DOWN. */
function isLiveForLabel(label, ageSec) {
  const ttl = label === "ram-memory" ? 120 : 45;
  return isLive(ageSec, ttl);
}

/** Human-readable one-line summary of tool args / command. */
export function formatDetail(e) {
  let args = e.args;
  if (!args && e.args_json) {
    try {
      args = typeof e.args_json === "string" ? JSON.parse(e.args_json) : e.args_json;
    } catch {
      args = null;
    }
  }
  if (!args || typeof args !== "object") {
    if (e.error) return String(e.error).slice(0, 120);
    return "";
  }
  if (args.command) return String(args.command).slice(0, 160);
  if (args.url) return String(args.url).slice(0, 120);
  if (args.path) {
    const p = String(args.path);
    const short = p.length > 90 ? "…" + p.slice(-87) : p;
    if (args.replacements != null) return `${short} · ${args.replacements} repl`;
    return short;
  }
  if (args.query) return String(args.query).slice(0, 120);
  if (args.key) return `key=${String(args.key).slice(0, 60)}`;
  if (args.pattern) return String(args.pattern).slice(0, 100);
  if (args.cwd) return `cwd ${String(args.cwd).slice(0, 80)}`;
  // generic first stringy field
  for (const [k, v] of Object.entries(args)) {
    if (typeof v === "string" && v.length && k !== "args_digest") {
      return `${k}=${v.slice(0, 100)}`;
    }
  }
  return "";
}

export function buildLiveFeed(events, limit = 60) {
  return events.slice(0, limit).map((e, i) => {
    const detail = formatDetail(e);
    return {
      id: `${e.timestamp || ""}-${e.tool || ""}-${e.client_id || ""}-${i}`,
      timestamp: e.timestamp || null,
      tool: e.tool || "?",
      status: e.status || "?",
      duration_ms: e.duration_ms ?? null,
      client_id: e.client_id || null,
      client_short: e.client_id ? String(e.client_id).slice(0, 8) : "—",
      detail,
      error: e.error || null,
    };
  });
}

/**
 * Semantic health for badges:
 *   ok (green)     — up, available, ready
 *   error (red)    — down / hard failure
 *   warn (yellow)  — degraded / elevated errors
 *   config (orange)— missing/misconfigured
 */
function mcpServerHealth({ live, pid, cwd, usage5, usage1h, role, registered }) {
  // Expected-but-offline family members: show as DOWN (not CONFIG) when registered in mcp.json
  if (!live) {
    if (registered) {
      return {
        health: "error",
        health_label: "DOWN",
        health_reason: "not connected — enable toggle in LM Studio",
      };
    }
    if (!cwd || String(cwd).trim() === "") {
      return { health: "config", health_label: "CONFIG", health_reason: "not registered" };
    }
    return { health: "error", health_label: "DOWN", health_reason: "heartbeat stale" };
  }
  if (pid == null || pid === 0) {
    return { health: "config", health_label: "CONFIG", health_reason: "missing pid" };
  }
  const er5 = usage5?.error_rate || 0;
  const er1 = usage1h?.error_rate || 0;
  const err5 = usage5?.error_count || 0;
  if (er5 >= 0.25 || (err5 >= 3 && usage5?.last_status && usage5.last_status !== "ok")) {
    return { health: "error", health_label: "ERROR", health_reason: `error_rate ${er5}` };
  }
  if (er5 > 0.05 || er1 > 0.1 || err5 > 0) {
    return { health: "warn", health_label: "WARN", health_reason: "elevated tool errors" };
  }
  if (role === "memory") {
    return { health: "ok", health_label: "READY", health_reason: "RAM corpus linked" };
  }
  if (role === "fallback") {
    return { health: "ok", health_label: "READY", health_reason: "fallback linked" };
  }
  return { health: "ok", health_label: "READY", health_reason: "live and healthy" };
}

function mcpToolHealth({ pack, usage_1h: u, status }) {
  const er = u?.error_rate || 0;
  const errc = u?.error_count || 0;
  const lastBad = u?.last_status && u.last_status !== "ok";

  // Config-sensitive packs: treat pure config-ish last failure lightly
  const configPacks = new Set(["research", "browser", "vsbuild", "github"]);

  if (er >= 0.25 || (errc >= 3 && lastBad)) {
    return { health: "error", health_label: "ERROR", health_reason: `error_rate ${er}` };
  }
  if (errc > 0 || lastBad) {
    // soft fail on config packs → orange when errors look like setup
    if (configPacks.has(pack) && er < 0.25) {
      return {
        health: "config",
        health_label: "CONFIG",
        health_reason: "errors on config-sensitive pack",
      };
    }
    return { health: "warn", health_label: "WARN", health_reason: "recent tool errors" };
  }
  if (pack === "other") {
    return { health: "config", health_label: "CONFIG", health_reason: "unknown tool" };
  }
  // Catalog tools with clean history: available / ready (idle is still green)
  if (status === "active" || status === "warm" || status === "idle") {
    return { health: "ok", health_label: "READY", health_reason: "available" };
  }
  return { health: "ok", health_label: "READY", health_reason: "available" };
}

export function buildMcpServers(presence, audit) {
  const registered = new Set(readRegisteredMcpServers());
  // Always include forge family first (ram-memory visible even when offline)
  const expectedLabels = [];
  for (const f of FORGE_FAMILY) {
    if (!expectedLabels.includes(f.label)) expectedLabels.push(f.label);
  }
  for (const k of registered) {
    if (!expectedLabels.includes(k)) expectedLabels.push(k);
  }

  // Latest live presence per label
  const byLabel = new Map();
  for (const p of presence || []) {
    const label = mcpLabelFromPresence(p);
    const prev = byLabel.get(label);
    const age = heartbeatAgeSec(p.last_heartbeat);
    const prevAge = prev ? heartbeatAgeSec(prev.last_heartbeat) : Infinity;
    if (!prev || (age != null && (prevAge == null || age < prevAge))) {
      byLabel.set(label, p);
    }
  }

  const cards = expectedLabels.map((label) => {
    const family = FORGE_FAMILY.find((f) => f.label === label) || {
      label,
      role: roleFromLabel(label),
      display: label,
      description: "MCP server",
    };
    const p = byLabel.get(label);
    const age = p ? heartbeatAgeSec(p.last_heartbeat) : null;
    const live = p ? isLiveForLabel(label, age) : false;
    let usage5 = p ? usageForClient(audit, p.client_id, 300) : emptyUsage();
    let usage15 = p ? usageForClient(audit, p.client_id, 900) : emptyUsage();
    let usage1h = p ? usageForClient(audit, p.client_id, 3600) : emptyUsage();
    // RAM Memory: also surface pack-level activity when calls went through either MCP
    if (label === "ram-memory") {
      const pack5 = usageForMemoryPack(audit, 300);
      const pack15 = usageForMemoryPack(audit, 900);
      const pack1h = usageForMemoryPack(audit, 3600);
      if (pack5.event_count > (usage5.event_count || 0)) usage5 = pack5;
      if (pack15.event_count > (usage15.event_count || 0)) usage15 = pack15;
      if (pack1h.event_count > (usage1h.event_count || 0)) usage1h = pack1h;
    }
    const role = family.role || roleFromLabel(label);
    const health = mcpServerHealth({
      live,
      pid: p?.pid,
      cwd: p?.cwd || (registered.has(label) ? `registered:${label}` : ""),
      usage5,
      usage1h,
      role,
      registered: registered.has(label) || FORGE_FAMILY.some((f) => f.label === label),
    });
    return {
      id: p?.client_id || `expected:${label}`,
      label,
      display: family.display || label,
      description: family.description || "",
      role,
      host_kind: p?.host_kind || (label === "ram-memory" ? "mcp/ram-memory" : "mcp"),
      pid: p?.pid ?? null,
      cwd: p?.cwd || null,
      last_heartbeat: p?.last_heartbeat || null,
      heartbeat_age_sec: age,
      live,
      registered: registered.has(label),
      status: live
        ? usage5.event_count > 0
          ? "active"
          : "idle"
        : registered.has(label)
          ? "offline"
          : "stale",
      ...health,
      usage_5m: usage5,
      usage_15m: usage15,
      usage_1h: usage1h,
      activity: Math.min(100, Math.round((usage5.events_per_min / 12) * 100)),
    };
  });

  // Sort: forge-family order (ram-memory first), live before offline within role preference
  const order = new Map(FORGE_FAMILY.map((f, i) => [f.label, i]));
  cards.sort((a, b) => {
    const oa = order.has(a.label) ? order.get(a.label) : 100;
    const ob = order.has(b.label) ? order.get(b.label) : 100;
    if (oa !== ob) return oa - ob;
    if (a.live !== b.live) return a.live ? -1 : 1;
    return (b.activity || 0) - (a.activity || 0);
  });
  return cards;
}

function listHomeAgents() {
  const dir = path.join(forgeHome(), "agents");
  if (!fs.existsSync(dir)) return [];
  try {
    return fs
      .readdirSync(dir)
      .filter((f) => f.endsWith(".md"))
      .map((f) => f.replace(/\.md$/i, ""));
  } catch {
    return [];
  }
}

/**
 * Per-tool MCP cards with usage indicators (all registered Forge tools).
 */
export function buildToolCards(audit, windowSec = 3600) {
  const now = Date.now() / 1000;
  const recent = (audit || []).filter((e) => {
    const t = parseTs(e.timestamp ?? e.ts);
    return t == null || now - t <= windowSec;
  });
  const recent5 = (audit || []).filter((e) => {
    const t = parseTs(e.timestamp ?? e.ts);
    return t == null || now - t <= 300;
  });

  const byTool = new Map();
  for (const e of recent) {
    const name = e.tool || "unknown";
    if (!byTool.has(name)) {
      byTool.set(name, {
        events: [],
        errors: 0,
        durations: [],
      });
    }
    const b = byTool.get(name);
    b.events.push(e);
    if ((e.status || "") !== "ok") b.errors += 1;
    if (typeof e.duration_ms === "number") b.durations.push(e.duration_ms);
  }

  const count5 = new Map();
  for (const e of recent5) {
    const name = e.tool || "unknown";
    count5.set(name, (count5.get(name) || 0) + 1);
  }

  const catalog = allToolsFlat();
  const known = new Set(catalog.map((c) => c.tool));
  // Include any audit-only tools not in catalog
  for (const name of byTool.keys()) {
    if (!known.has(name)) {
      catalog.push({ tool: name, pack: packForTool(name) });
    }
  }

  const spanMin = Math.max(windowSec / 60, 1);
  const spanMin5 = 5;

  const cards = catalog.map(({ tool, pack }) => {
    const b = byTool.get(tool);
    const eventCount = b?.events.length || 0;
    const errCount = b?.errors || 0;
    const e5 = count5.get(tool) || 0;
    const epm = Math.round((eventCount / spanMin) * 100) / 100;
    const epm5 = Math.round((e5 / spanMin5) * 100) / 100;
    const last = b?.events[0] || null;
    const durs = b?.durations || [];
    const avgMs = durs.length
      ? Math.round((durs.reduce((a, c) => a + c, 0) / durs.length) * 10) / 10
      : null;
    // Activity: prioritize 5m burst, scale ~0–100
    const activity = Math.min(100, Math.round(epm5 * 25 + epm * 8 + (eventCount > 0 ? 8 : 0)));
    let status = "idle";
    if (e5 > 0) status = "active";
    else if (eventCount > 0) status = "warm";
    const usage_1h = {
      event_count: eventCount,
      events_per_min: epm,
      error_count: errCount,
      error_rate: Math.round((errCount / Math.max(eventCount, 1)) * 1000) / 1000,
      duration_ms_avg: avgMs,
      last_status: last?.status || null,
      last_ts: last?.timestamp || null,
    };
    const usage_5m = {
      event_count: e5,
      events_per_min: epm5,
    };
    const health = mcpToolHealth({ pack, usage_1h, status });
    return {
      tool,
      pack,
      status,
      live: e5 > 0,
      activity,
      ...health,
      usage_1h,
      usage_5m,
    };
  });

  cards.sort((a, b) => {
    if (a.live !== b.live) return a.live ? -1 : 1;
    if ((b.activity || 0) !== (a.activity || 0)) return (b.activity || 0) - (a.activity || 0);
    if ((b.usage_1h?.event_count || 0) !== (a.usage_1h?.event_count || 0)) {
      return (b.usage_1h?.event_count || 0) - (a.usage_1h?.event_count || 0);
    }
    if (a.pack !== b.pack) return a.pack.localeCompare(b.pack);
    return a.tool.localeCompare(b.tool);
  });

  // Pack rollups for panel meta / optional headers
  const packs = TOOL_PACKS.map((p) => {
    const tools = cards.filter((c) => c.pack === p.pack);
    const events = tools.reduce((s, t) => s + (t.usage_1h?.event_count || 0), 0);
    const active = tools.filter((t) => t.live || t.status === "active").length;
    return {
      pack: p.pack,
      tool_count: tools.length,
      event_count_1h: events,
      active_tools: active,
      activity: Math.min(
        100,
        Math.round(tools.reduce((s, t) => s + (t.activity || 0), 0) / Math.max(tools.length, 1))
      ),
    };
  }).sort((a, b) => b.event_count_1h - a.event_count_1h || a.pack.localeCompare(b.pack));

  return { tools: cards, packs };
}

export function buildAgentCards(sessions, audit) {
  const catalog = new Set([...KNOWN_AGENTS, ...listHomeAgents()]);
  const byId = new Map();

  for (const id of catalog) {
    byId.set(id, {
      agent_id: id,
      status: "idle",
      sessions: [],
      client_ids: [],
      live: false,
      activity: 0,
      usage_15m: usageForClient([], null, 900),
      last_ts: null,
      summary: null,
    });
  }

  for (const s of sessions || []) {
    const id = s.agent_id || "unknown";
    if (!byId.has(id)) {
      byId.set(id, {
        agent_id: id,
        status: "idle",
        sessions: [],
        client_ids: [],
        live: false,
        activity: 0,
        usage_15m: usageForClient([], null, 900),
        last_ts: null,
        summary: null,
      });
    }
    const card = byId.get(id);
    card.sessions.push({
      id: s.id,
      status: s.status,
      client_id: s.client_id,
      updated_at: s.updated_at,
      created_at: s.created_at,
    });
    if (s.client_id) card.client_ids.push(s.client_id);
    if (s.summary) card.summary = s.summary;
    const st = (s.status || "").toLowerCase();
    if (["active", "running", "open", "started"].includes(st)) {
      card.status = st === "open" ? "open" : "active";
      card.live = true;
    } else if (card.status === "idle" && st) {
      card.status = st;
    }
    const ut = parseTs(s.updated_at);
    if (ut && (!card.last_ts || ut > parseTs(card.last_ts))) {
      card.last_ts = s.updated_at;
    }
  }

  // Attribute audit usage via session client_ids
  for (const card of byId.values()) {
    if (!card.client_ids.length) continue;
    const mine = (audit || []).filter((e) => card.client_ids.includes(e.client_id));
    card.usage_15m = usageForClient(mine, null, 900);
    // if no client filter needed — already filtered
    const u = summarizeTools(mine, 900);
    card.usage_15m = {
      event_count: u.event_count,
      events_per_min: u.events_per_min,
      error_count: u.error_count,
      error_rate: u.error_rate,
      top_tools: u.top_tools.slice(0, 5),
      last_tool: mine[0]?.tool || null,
      last_status: mine[0]?.status || null,
      last_ts: mine[0]?.timestamp || null,
    };
    card.activity = Math.min(100, Math.round((u.events_per_min / 8) * 100));
    if (u.event_count > 0 && card.status === "idle") {
      card.status = "active";
      card.live = true;
    }
  }

  const list = [...byId.values()];
  list.sort((a, b) => {
    if (a.live !== b.live) return a.live ? -1 : 1;
    if ((b.activity || 0) !== (a.activity || 0)) return (b.activity || 0) - (a.activity || 0);
    if (a.status !== "idle" && b.status === "idle") return -1;
    if (b.status !== "idle" && a.status === "idle") return 1;
    return a.agent_id.localeCompare(b.agent_id);
  });
  return list;
}

export function collectForge() {
  const home = forgeHome();
  const auditSql = collectAuditSql(150);
  const auditJsonl = collectAuditJsonl(200);
  // Prefer jsonl (has args for live feed); merge-ish by using jsonl when present
  const audit = auditJsonl.length ? auditJsonl : auditSql;
  const sessions = collectAgentSessions(50);
  const presence = collectPresence();
  const jobs = collectJobs(30);
  const mcpServers = buildMcpServers(presence, audit);
  const agents = buildAgentCards(sessions, audit);
  const liveFeed = buildLiveFeed(audit, 80);
  const toolCards = buildToolCards(audit, 3600);

  return {
    ts: Date.now() / 1000,
    home,
    presence,
    presence_count: presence.length,
    mcp_servers: mcpServers,
    mcp_tools: toolCards.tools,
    mcp_packs: toolCards.packs,
    agents,
    agent_sessions: sessions.slice(0, 25),
    agents_summary: summarizeAgents(sessions),
    jobs: jobs.slice(0, 20),
    audit_recent: audit.slice(0, 40),
    live_feed: liveFeed,
    mcp_load: {
      "1h": summarizeTools(audit, 3600),
      "15m": summarizeTools(audit, 900),
      "5m": summarizeTools(audit, 300),
    },
    files: {
      store_sqlite: fs.existsSync(path.join(home, "store.sqlite")),
      audit_jsonl: fs.existsSync(path.join(home, "audit.jsonl")),
      supervisor_log: fs.existsSync(path.join(home, "logs", "supervisor.log")),
    },
  };
}

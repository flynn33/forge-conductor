#!/usr/bin/env node
/**
 * Forge Rig Telemetry — Node browser dashboard (LAN-accessible).
 *
 * Separate process from forge-conductor MCP serve/supervise.
 * Read-only sidecar. No auth (trusted LAN by design).
 * Default bind: 0.0.0.0 (all interfaces). Set TELEMETRY_HOST=127.0.0.1 for local-only.
 */
import express from "express";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { collectSystem } from "./lib/system.js";
import { collectForge } from "./lib/forge.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = __dirname;

const HOST = process.env.TELEMETRY_HOST || "0.0.0.0";
const PORT = Number(process.env.TELEMETRY_PORT || 7788);
const INTERVAL = Number(process.env.TELEMETRY_INTERVAL || 2);

function lanAddresses() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces || {})) {
    for (const info of ifaces[name] || []) {
      if (info.family === "IPv4" && !info.internal) out.push(info.address);
    }
  }
  return out;
}

const HISTORY_MAX = 180;
const cache = { system: null, forge: null, updated: 0 };
const history = [];

/** JSON-safe (BigInt → number/string). */
function safeJson(obj) {
  return JSON.stringify(obj, (_k, v) => {
    if (typeof v === "bigint") {
      return Number.isSafeInteger(Number(v)) ? Number(v) : v.toString();
    }
    return v;
  });
}

async function refresh(force = false) {
  const now = Date.now() / 1000;
  if (!force && cache.system && now - cache.updated < 1.5) {
    return {
      system: cache.system,
      forge: cache.forge,
      updated: cache.updated,
      history: history.slice(-120),
    };
  }

  let system;
  let forge;
  try {
    system = await collectSystem();
  } catch (exc) {
    system = { error: String(exc), ts: now, cpu: { percent: 0 }, ram: { percent: 0 }, gpu: [], disk: [], processes: [] };
  }
  try {
    forge = collectForge();
  } catch (exc) {
    forge = { error: String(exc), ts: now, presence_count: 0, mcp_load: {}, files: {} };
  }

  const snap = {
    ts: now,
    cpu: system?.cpu?.percent ?? null,
    ram: system?.ram?.percent ?? null,
    gpu: null,
    gpu_mem: null,
    power: null,
    mcp_epm_5m: forge?.mcp_load?.["5m"]?.events_per_min ?? null,
    mcp_errors_5m: forge?.mcp_load?.["5m"]?.error_count ?? null,
    presence: forge?.presence_count ?? null,
  };
  const gpus = system?.gpu || [];
  if (gpus[0]) {
    snap.gpu = gpus[0].util_gpu;
    snap.gpu_mem = gpus[0].mem_used_mib;
    snap.power = gpus[0].power_w;
  }

  cache.system = system;
  cache.forge = forge;
  cache.updated = now;
  history.push(snap);
  while (history.length > HISTORY_MAX) history.shift();

  return {
    system,
    forge,
    updated: now,
    history: history.slice(-120),
  };
}

function bgLoop(intervalSec) {
  const tick = async () => {
    try {
      await refresh(true);
    } catch {
      /* ignore */
    }
    setTimeout(tick, intervalSec * 1000);
  };
  tick();
}

const FORGE_HOME =
  process.env.FORGE_CONDUCTOR_HOME || path.join(os.homedir(), ".forge-conductor");
const STACK_PS1 = path.join(FORGE_HOME, "scripts", "forge-stack.ps1");
const STACK_STATE = path.join(FORGE_HOME, "stack-state.json");
const RAMDISK_STATE = path.join(FORGE_HOME, "ramdisk-state.json");
const RAMDISK_CONFIG = path.join(FORGE_HOME, "ramdisk-config.json");
const AGENT_BACKEND_STATE = path.join(FORGE_HOME, "agent_backend.json");
const STACK_ROLES = ["primary", "fallback", "memory"];

/** Resolve python without machine-specific hardcodes. */
function resolveForgePython() {
  const candidates = [
    process.env.FORGE_PYTHON,
    "R:\\app\\.venv\\Scripts\\python.exe",
    path.join(os.homedir(), ".forge-conductor", ".venv", "Scripts", "python.exe"),
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p)) || null;
}

/** Optional package source root for PYTHONPATH (installed package preferred). */
function resolveForgeSourceRoot() {
  if (process.env.FORGE_SOURCE_ROOT && fs.existsSync(process.env.FORGE_SOURCE_ROOT)) {
    return process.env.FORGE_SOURCE_ROOT;
  }
  if (fs.existsSync("R:\\app\\src")) return "R:\\app\\src";
  const homeSrc = path.join(os.homedir(), ".forge-conductor", "src");
  if (fs.existsSync(homeSrc)) return homeSrc;
  return "";
}

/** Python snippet to prepend optional sys.path insert. */
function pythonPathInsertLine() {
  const src = resolveForgeSourceRoot();
  if (!src) return "";
  return `sys.path.insert(0, ${JSON.stringify(src)})\n`;
}

/** True if Windows PID is alive (no PowerShell). */
function pidAlive(pid) {
  const n = Number(pid);
  if (!Number.isFinite(n) || n <= 0) return false;
  try {
    // Node on Windows: kill(pid, 0) throws if missing in recent versions
    process.kill(n, 0);
    return true;
  } catch (e) {
    // ESRCH / EINVAL → dead; EPERM → exists but no permission (still alive)
    if (e && (e.code === "EPERM" || e.code === "EACCES")) return true;
    return false;
  }
}

/** Read ramdisk config + state + letter root presence (fast, no pwsh). */
function readRamdiskStatus() {
  let cfg = {
    letter: "R",
    size_gb: 16,
    size_gb_min: 16,
    size_gb_max: 32,
    provider: "imdisk",
  };
  let st = {
    mounted: false,
    letter: null,
    size_gb: null,
    last_snapshot: null,
    last_snapshot_ok: false,
    last_tier: null,
    last_error: null,
    created_at: null,
  };
  try {
    if (fs.existsSync(RAMDISK_CONFIG)) {
      cfg = { ...cfg, ...JSON.parse(fs.readFileSync(RAMDISK_CONFIG, "utf8")) };
    }
  } catch {
    /* ignore */
  }
  try {
    if (fs.existsSync(RAMDISK_STATE)) {
      st = { ...st, ...JSON.parse(fs.readFileSync(RAMDISK_STATE, "utf8")) };
    }
  } catch {
    /* ignore */
  }
  const letter = String(cfg.letter || st.letter || "R").replace(":", "");
  const root = `${letter}:\\`;
  let mounted = false;
  try {
    mounted = fs.existsSync(root);
  } catch {
    mounted = false;
  }
  let liveHomeOk = false;
  let liveAppOk = false;
  try {
    liveHomeOk = fs.existsSync(path.join(`${letter}:\\`, "home"));
    liveAppOk = fs.existsSync(path.join(`${letter}:\\`, "app", ".venv"));
  } catch {
    /* ignore */
  }
  return {
    provider: cfg.provider || "imdisk",
    letter,
    mounted,
    size_gb_config: Number(cfg.size_gb) || 16,
    size_gb_min: Number(cfg.size_gb_min) || 16,
    size_gb_max: Number(cfg.size_gb_max) || 32,
    size_gb_state: st.size_gb || null,
    live_home_ok: liveHomeOk,
    live_app_ok: liveAppOk,
    last_snapshot: st.last_snapshot || null,
    last_snapshot_ok: !!st.last_snapshot_ok,
    last_tier: st.last_tier || null,
    last_error: st.last_error || null,
    created_at: st.created_at || null,
    snapshot_interval_sec: Number(cfg.snapshot_interval_sec) || 30,
    tier_chunk_gb: Number(cfg.tier_chunk_gb) || 1,
  };
}

/** Fast stack status — read state file + PID checks (no pwsh spawn). */
function readStackStatus() {
  let st = {
    desired: "unloaded",
    loaded_at: null,
    unloaded_at: null,
    pids: {},
    supervise_pid: null,
  };
  try {
    if (fs.existsSync(STACK_STATE)) {
      st = { ...st, ...JSON.parse(fs.readFileSync(STACK_STATE, "utf8")) };
    }
  } catch (e) {
    return {
      ok: false,
      error: String(e),
      desired: "unloaded",
      loaded: false,
      roles: Object.fromEntries(STACK_ROLES.map((r) => [r, false])),
      process_count: 0,
      processes: [],
      mode: "ramdisk-on-demand",
      autostart: false,
      ramdisk: readRamdiskStatus(),
    };
  }
  const pids = st.pids || {};
  const roles = {};
  const processes = [];
  for (const r of STACK_ROLES) {
    const pid = pids[r];
    const alive = pidAlive(pid);
    roles[r] = alive;
    if (alive) processes.push({ Pid: Number(pid), Role: r });
  }
  const liveCount = processes.length;
  const desired = st.desired || "unloaded";
  const ramdisk = readRamdiskStatus();
  const fully =
    desired === "loaded" &&
    liveCount === STACK_ROLES.length &&
    !!ramdisk.mounted;
  const partial =
    desired === "loaded" &&
    !fully &&
    (liveCount > 0 || !!ramdisk.mounted);
  return {
    ok: true,
    desired,
    loaded: fully,
    partially_loaded: partial,
    roles,
    process_count: liveCount,
    processes,
    loaded_at: st.loaded_at || null,
    unloaded_at: st.unloaded_at || null,
    supervise_pid: st.supervise_pid || null,
    supervise_alive: pidAlive(st.supervise_pid),
    state_path: STACK_STATE,
    mode: "ramdisk-on-demand",
    restart_policy: "on_failure_while_loaded",
    autostart: false,
    ramdisk,
  };
}

function runStackAction(action, timeoutMs = 120_000) {
  return new Promise((resolve) => {
    if (!fs.existsSync(STACK_PS1)) {
      resolve({ ok: false, error: `missing ${STACK_PS1}` });
      return;
    }
    const args = [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      STACK_PS1,
      "-Action",
      action,
      "-Quiet",
    ];
    const child = spawn("pwsh", args, {
      windowsHide: true,
      cwd: path.dirname(STACK_PS1),
    });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
      resolve({ ok: false, error: "timeout", stdout: out, stderr: err });
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      out += d.toString();
    });
    child.stderr.on("data", (d) => {
      err += d.toString();
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      let parsed = null;
      const lines = out
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter(Boolean);
      for (let i = lines.length - 1; i >= 0; i--) {
        if (lines[i].startsWith("{") || lines[i].startsWith("[")) {
          try {
            parsed = JSON.parse(lines.slice(i).join("\n"));
            break;
          } catch {
            try {
              parsed = JSON.parse(lines[i]);
              break;
            } catch {
              /* continue */
            }
          }
        }
      }
      resolve({
        ok: code === 0,
        exit_code: code,
        action,
        result: parsed,
        stdout_tail: out.slice(-2000),
        stderr_tail: err.slice(-1000),
      });
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      resolve({ ok: false, error: String(e) });
    });
  });
}

const app = express();
// Disable ETag caching for API freshness
app.set("etag", false);
app.use(express.json({ limit: "256kb" }));

// Dashboard + stack control — no auth. Trusted LAN / local network.
app.use((req, res, next) => {
  res.setHeader("Cache-Control", "no-store, no-cache, must-revalidate");
  // Allow browser clients on the LAN
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});

app.use(
  "/static",
  express.static(path.join(ROOT, "static"), {
    etag: false,
    maxAge: 0,
    setHeaders(res) {
      res.setHeader("Cache-Control", "no-store");
    },
  })
);

app.get(["/", "/index.html"], (_req, res) => {
  const htmlPath = path.join(ROOT, "static", "index.html");
  res.type("html").send(fs.readFileSync(htmlPath, "utf8"));
});

app.get("/api/health", (_req, res) => {
  res.json({
    ok: true,
    service: "forge-telemetry",
    runtime: "node",
    interferes_with_mcp: false,
    mode: "dashboard+stack-control+ramdisk",
    auth: false,
    bind: HOST,
    port: PORT,
    lan_urls: lanAddresses().map((ip) => `http://${ip}:${PORT}/`),
    pid: process.pid,
    uptime_s: Math.round(process.uptime()),
    ts: Date.now() / 1000,
    stack_control: true,
    ramdisk: true,
  });
});

/** On-demand Forge stack — status is pure Node (instant). load/unload spawn pwsh. */
app.get("/api/stack", (_req, res) => {
  try {
    res.type("json").send(safeJson(readStackStatus()));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

function findPwsh() {
  const candidates = [
    path.join(process.env.ProgramFiles || "C:\\Program Files", "PowerShell", "7", "pwsh.exe"),
    path.join(process.env.LOCALAPPDATA || "", "Microsoft", "WindowsApps", "pwsh.exe"),
    "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  ];
  for (const c of candidates) {
    try {
      if (c && fs.existsSync(c)) return c;
    } catch {
      /* ignore */
    }
  }
  return "pwsh.exe";
}

function fireStackAction(action) {
  if (!fs.existsSync(STACK_PS1)) {
    return { ok: false, error: `missing ${STACK_PS1}` };
  }
  const logDir = path.join(FORGE_HOME, "logs");
  fs.mkdirSync(logDir, { recursive: true });
  const fireLog = path.join(logDir, "stack-control.log");
  const childLog = path.join(logDir, `stack-fire-${action}.log`);
  const stamp = new Date().toISOString();
  try {
    fs.appendFileSync(fireLog, `[${stamp}] dashboard fire action=${action}\n`, "utf8");
  } catch {
    /* ignore */
  }

  const pwsh = findPwsh();
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    STACK_PS1,
    "-Action",
    action,
    "-Quiet",
  ];

  let outFd;
  try {
    outFd = fs.openSync(childLog, "a");
    fs.writeSync(outFd, `\n--- fire ${action} ${stamp} pwsh=${pwsh} ---\n`);
  } catch {
    outFd = "ignore";
  }

  // Non-detached child of telemetry node: reliable on Windows; survives until done.
  // Do not wait — respond immediately; script writes stack-state.json.
  const child = spawn(pwsh, args, {
    windowsHide: true,
    cwd: path.dirname(STACK_PS1),
    detached: false,
    stdio: outFd === "ignore" ? "ignore" : ["ignore", outFd, outFd],
    env: { ...process.env, FORGE_CONDUCTOR_HOME: FORGE_HOME },
  });
  child.on("error", (e) => {
    try {
      fs.appendFileSync(fireLog, `[${new Date().toISOString()}] fire spawn error: ${e}\n`, "utf8");
    } catch {
      /* ignore */
    }
  });
  child.on("exit", (code) => {
    try {
      fs.appendFileSync(
        fireLog,
        `[${new Date().toISOString()}] fire exit action=${action} code=${code}\n`,
        "utf8"
      );
    } catch {
      /* ignore */
    }
  });
  return {
    ok: true,
    action,
    async: true,
    pid: child.pid,
    script: STACK_PS1,
    pwsh,
  };
}

app.post("/api/stack/load", async (_req, res) => {
  try {
    // Fire-and-forget: dashboard polls /api/stack until loaded
    const r = fireStackAction("load");
    res.type("json").send(safeJson(r));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.post("/api/stack/unload", async (_req, res) => {
  try {
    const r = fireStackAction("unload");
    res.type("json").send(safeJson(r));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.post("/api/stack/warm", async (_req, res) => {
  try {
    const r = await runStackAction("warm", 60_000);
    res.type("json").send(safeJson(r));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.post("/api/stack/restart", async (_req, res) => {
  try {
    // Fire-and-forget: full unload+load (RAM disk recycle)
    const r = fireStackAction("restart");
    res.type("json").send(safeJson(r));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.post("/api/stack/snapshot", async (_req, res) => {
  try {
    const r = await runStackAction("snapshot", 120_000);
    res.type("json").send(safeJson(r));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.get("/api/ramdisk", (_req, res) => {
  try {
    res.type("json").send(safeJson({ ok: true, ...readRamdiskStatus() }));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

/** Agent backend HOST|GROK — read state file + worker heartbeat (fast). */
function readAgentBackendStatus() {
  let st = {
    mode: "host",
    generation: 0,
    policy: { when_grok_block_host_mutations: true },
    grok: {},
    notify: {},
  };
  try {
    if (fs.existsSync(AGENT_BACKEND_STATE)) {
      st = { ...st, ...JSON.parse(fs.readFileSync(AGENT_BACKEND_STATE, "utf8")) };
    }
  } catch {
    /* ignore */
  }
  const mode = st.mode === "grok" ? "grok" : "host";
  let workerAlive = false;
  let heartbeatAge = null;
  try {
    const hb = path.join(FORGE_HOME, "logs", "grok-worker.heartbeat");
    if (fs.existsSync(hb)) {
      const age = (Date.now() - fs.statSync(hb).mtimeMs) / 1000;
      heartbeatAge = Math.round(age * 10) / 10;
      workerAlive = age < 45;
    }
  } catch {
    /* ignore */
  }
  const keyEnv = (st.grok && st.grok.api_key_env) || "XAI_API_KEY";
  const apiKeyConfigured = !!(process.env[keyEnv] || "");
  // secrets.env presence (not reading value)
  let secretsPresent = false;
  try {
    secretsPresent = fs.existsSync(path.join(FORGE_HOME, "secrets.env"));
  } catch {
    /* ignore */
  }
  // Grok Build heartbeat (primary) — no API key required
  let grokBuildAttached = false;
  let gbAge = null;
  try {
    const gbh = path.join(FORGE_HOME, "logs", "grok-build.heartbeat");
    if (fs.existsSync(gbh)) {
      gbAge = (Date.now() - fs.statSync(gbh).mtimeMs) / 1000;
      grokBuildAttached = gbAge < 120;
    }
  } catch {
    /* ignore */
  }
  let connectPrompt = null;
  try {
    const cp = path.join(FORGE_HOME, "lmstudio", "grok-build-connect-prompt.md");
    if (fs.existsSync(cp)) connectPrompt = fs.readFileSync(cp, "utf8");
  } catch {
    /* ignore */
  }
  return {
    ok: true,
    mode,
    generation: st.generation || 0,
    executor: mode === "grok" ? "grok_build" : "host",
    policy: {
      mode,
      generation: st.generation || 0,
      policy: mode === "grok" ? "MANDATORY_OFFLOAD" : "HOST_EXECUTES_AGENTS",
      executor: mode === "grok" ? "grok_build" : "host",
    },
    policy_flags: st.policy || {},
    last_changed_at: st.last_changed_at || null,
    last_changed_by: st.last_changed_by || null,
    notify: st.notify || {},
    worker: {
      executor: "grok_build",
      grok_build_attached: grokBuildAttached,
      worker_alive: grokBuildAttached || workerAlive,
      worker_heartbeat_age_sec: gbAge != null ? Math.round(gbAge * 10) / 10 : heartbeatAge,
      api_key_required: false,
      api_key_configured: apiKeyConfigured || secretsPresent,
      api_key_env: keyEnv,
      model: (st.grok && st.grok.model) || null,
    },
    connect_prompt: connectPrompt,
    connect_prompt_available: !!connectPrompt && mode === "grok",
    connect_prompt_path: path.join(FORGE_HOME, "lmstudio", "grok-build-connect-prompt.md"),
    state_path: AGENT_BACKEND_STATE,
  };
}

app.get("/api/agent-backend", (_req, res) => {
  try {
    res.type("json").send(safeJson(readAgentBackendStatus()));
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.get("/api/agent-backend/connect-prompt", (_req, res) => {
  try {
    const st = readAgentBackendStatus();
    let prompt = st.connect_prompt || "";
    if (!prompt) {
      // generate via python if missing
      const py = resolveForgePython();
      if (py) {
        const r = spawnSync(
          py,
          [
            "-c",
            `import os,sys,json
os.environ["FORGE_CONDUCTOR_HOME"]=r"""${FORGE_HOME.replace(/\\/g, "\\\\")}"""
${pythonPathInsertLine()}from forge_conductor.agent_backend import build_grok_build_connect_prompt, write_connect_prompt
write_connect_prompt()
print(build_grok_build_connect_prompt())
`,
          ],
          { encoding: "utf8", timeout: 15000, windowsHide: true }
        );
        if (r.stdout) prompt = r.stdout;
      }
    }
    res.type("json").send(
      safeJson({
        ok: true,
        mode: st.mode,
        generation: st.generation,
        prompt,
        path: st.connect_prompt_path,
      })
    );
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.post("/api/agent-backend", async (req, res) => {
  try {
    const mode = String((req.body && req.body.mode) || "").toLowerCase();
    if (mode !== "host" && mode !== "grok") {
      res.status(400).json({ ok: false, error: "mode must be host|grok" });
      return;
    }
    const reason = (req.body && req.body.reason) || "dashboard";
    const notify = req.body && req.body.notify === false ? false : true;
    // Prefer live home if RAM disk loaded
    const liveHome = "R:\\home";
    const home =
      fs.existsSync(path.join(liveHome, "store.sqlite")) || fs.existsSync(path.join(liveHome, "bin"))
        ? liveHome
        : FORGE_HOME;
    let py = resolveForgePython();
    if (!py) {
      res.status(500).json({ ok: false, error: "python venv not found — set FORGE_PYTHON" });
      return;
    }
    const { spawn } = await import("node:child_process");
    // -c does not take argv after script on Windows well — use env + inline
    const env = { ...process.env, FORGE_CONDUCTOR_HOME: home };
    const child = spawn(
      py,
      [
        "-c",
        `
import os, json
os.environ["FORGE_CONDUCTOR_HOME"] = ${JSON.stringify(home)}
import sys
${pythonPathInsertLine()}from forge_conductor.agent_backend import set_mode, status_payload
st = set_mode(${JSON.stringify(mode)}, changed_by="dashboard", reason=${JSON.stringify(reason)}, notify=${notify ? "True" : "False"})
print(json.dumps(status_payload()))
`,
      ],
      { env, windowsHide: true }
    );
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
    }, 90_000);
    child.stdout.on("data", (d) => {
      out += d.toString();
    });
    child.stderr.on("data", (d) => {
      err += d.toString();
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      let parsed = null;
      const lines = out
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter(Boolean);
      for (let i = lines.length - 1; i >= 0; i--) {
        if (lines[i].startsWith("{")) {
          try {
            parsed = JSON.parse(lines[i]);
            break;
          } catch {
            /* continue */
          }
        }
      }
      if (parsed) {
        // Ensure connect_prompt text is present for GROK popup
        if (parsed.mode === "grok" && !parsed.connect_prompt) {
          try {
            const cp = path.join(FORGE_HOME, "lmstudio", "grok-build-connect-prompt.md");
            if (fs.existsSync(cp)) {
              parsed.connect_prompt = fs.readFileSync(cp, "utf8");
            }
          } catch {
            /* ignore */
          }
        }
        res.type("json").send(safeJson(parsed));
      } else {
        res.status(500).json({
          ok: false,
          error: "set_mode failed",
          exit_code: code,
          stderr_tail: err.slice(-800),
          stdout_tail: out.slice(-800),
        });
      }
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e) });
  }
});

app.get("/api/snapshot", async (_req, res) => {
  try {
    res.type("json").send(safeJson(await refresh(false)));
  } catch (e) {
    res.status(500).json({ error: String(e) });
  }
});

app.get("/api/system", async (_req, res) => {
  try {
    const s = await refresh(false);
    res.type("json").send(safeJson(s.system));
  } catch (e) {
    res.status(500).json({ error: String(e) });
  }
});

app.get("/api/forge", async (_req, res) => {
  try {
    const s = await refresh(false);
    res.type("json").send(safeJson(s.forge));
  } catch (e) {
    res.status(500).json({ error: String(e) });
  }
});

app.get("/api/stream", async (req, res) => {
  let interval = Number(req.query.interval || 2);
  if (!Number.isFinite(interval)) interval = 2;
  interval = Math.max(1, Math.min(interval, 10));

  res.status(200);
  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  // Disable Node HTTP response buffering where possible
  if (typeof res.flushHeaders === "function") res.flushHeaders();
  res.write(": connected\n\n");

  let closed = false;
  const onClose = () => {
    closed = true;
  };
  req.on("close", onClose);
  req.on("aborted", onClose);

  while (!closed) {
    try {
      const snap = await refresh(true);
      if (closed) break;
      res.write(`data: ${safeJson(snap)}\n\n`);
    } catch (e) {
      if (!closed) res.write(`data: ${safeJson({ error: String(e) })}\n\n`);
    }
    await new Promise((r) => setTimeout(r, interval * 1000));
  }
});

const server = app.listen(PORT, HOST, async () => {
  console.log(`Forge Telemetry (Node)  bind ${HOST}:${PORT}`);
  console.log(`  local  →  http://127.0.0.1:${PORT}/`);
  for (const ip of lanAddresses()) {
    console.log(`  lan    →  http://${ip}:${PORT}/`);
  }
  console.log(`pid=${process.pid}  read-only · no auth · MCP-safe · LAN open`);
  try {
    await refresh(true);
    console.log("initial snapshot OK");
  } catch (e) {
    console.warn("initial refresh:", e.message || e);
  }
  bgLoop(INTERVAL);
});

// Keep sockets alive for SSE
server.keepAliveTimeout = 120_000;
server.headersTimeout = 125_000;

server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    console.error(`Port ${PORT} in use. Stop the other process or set TELEMETRY_PORT.`);
  } else {
    console.error(err);
  }
  process.exit(1);
});

process.on("uncaughtException", (err) => {
  console.error("uncaughtException", err);
  process.exit(1); // supervise will restart
});
process.on("unhandledRejection", (err) => {
  console.error("unhandledRejection", err);
});

/**
 * System telemetry: CPU, RAM, disk, GPU (nvidia-smi), hot processes.
 * Non-invasive — no writes, no MCP.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import si from "systeminformation";

const execFileAsync = promisify(execFile);

function num(v) {
  if (v == null || v === "" || v === "[N/A]" || v === "N/A") return null;
  const n = Number(String(v).trim());
  return Number.isFinite(n) ? n : null;
}

export async function collectCpu() {
  // Destructure carefully — names must match API results
  const [load, cpuInfo, speed] = await Promise.all([
    si.currentLoad(),
    si.cpu(),
    si.cpuCurrentSpeed(),
  ]);
  const perCpu = (load.cpus || []).map((c) => Math.round((c.load ?? 0) * 10) / 10);
  const logical =
    (typeof cpuInfo.cores === "number" && cpuInfo.cores) ||
    perCpu.length ||
    null;
  const physical =
    (typeof cpuInfo.physicalCores === "number" && cpuInfo.physicalCores) || null;
  // speed.avg is GHz; speed.cores is per-core GHz array — do not use as count
  const freqMhz =
    (typeof speed.avg === "number" && speed.avg > 0
      ? Math.round(speed.avg * 1000)
      : null) ||
    (typeof cpuInfo.speed === "number" && cpuInfo.speed > 0
      ? Math.round(cpuInfo.speed * 1000)
      : null);
  return {
    percent: Math.round((load.currentLoad ?? 0) * 10) / 10,
    per_cpu: perCpu,
    count_logical: logical,
    count_physical: physical,
    freq_mhz: freqMhz,
    load_avg: null,
  };
}

export async function collectRam() {
  const mem = await si.mem();
  const total = mem.total || 0;
  const used = mem.used || 0;
  const available = mem.available ?? mem.free ?? 0;
  const swTotal = mem.swaptotal || 0;
  const swUsed = mem.swapused || 0;
  return {
    total_gb: Math.round((total / 1024 ** 3) * 100) / 100,
    used_gb: Math.round((used / 1024 ** 3) * 100) / 100,
    available_gb: Math.round((available / 1024 ** 3) * 100) / 100,
    percent: total ? Math.round((used / total) * 1000) / 10 : 0,
    swap_total_gb: Math.round((swTotal / 1024 ** 3) * 100) / 100,
    swap_used_gb: Math.round((swUsed / 1024 ** 3) * 100) / 100,
    swap_percent: swTotal ? Math.round((swUsed / swTotal) * 1000) / 10 : 0,
  };
}

export async function collectDisk() {
  const fsSize = await si.fsSize();
  return (fsSize || [])
    .filter((d) => d.size > 0 && d.mount)
    .map((d) => ({
      device: d.fs || d.mount,
      mount: d.mount,
      fstype: d.type || "",
      total_gb: Math.round((d.size / 1024 ** 3) * 10) / 10,
      used_gb: Math.round((d.used / 1024 ** 3) * 10) / 10,
      percent: Math.round((d.use ?? 0) * 10) / 10,
    }));
}

async function runNvidiaSmi(args) {
  try {
    const { stdout } = await execFileAsync("nvidia-smi", args, {
      timeout: 5000,
      windowsHide: true,
      maxBuffer: 2 * 1024 * 1024,
    });
    return stdout || "";
  } catch {
    return "";
  }
}

export async function collectGpu() {
  const query =
    "name,utilization.gpu,utilization.memory,memory.used,memory.total," +
    "memory.free,temperature.gpu,power.draw,power.limit," +
    "clocks.current.sm,clocks.max.sm,clocks.current.memory";
  const out = await runNvidiaSmi([
    `--query-gpu=${query}`,
    "--format=csv,noheader,nounits",
  ]);
  if (!out.trim()) return [];

  const gpus = [];
  for (const line of out.trim().split(/\r?\n/)) {
    const parts = line.split(",").map((p) => p.trim());
    if (parts.length < 12) continue;
    gpus.push({
      name: parts[0],
      util_gpu: num(parts[1]),
      util_mem: num(parts[2]),
      mem_used_mib: num(parts[3]),
      mem_total_mib: num(parts[4]),
      mem_free_mib: num(parts[5]),
      temp_c: num(parts[6]),
      power_w: num(parts[7]),
      power_limit_w: num(parts[8]),
      clock_sm_mhz: num(parts[9]),
      clock_sm_max_mhz: num(parts[10]),
      clock_mem_mhz: num(parts[11]),
    });
  }

  // Only real compute apps with GPU memory (skip desktop/display noise)
  try {
    const pOut = await runNvidiaSmi([
      "--query-compute-apps=pid,process_name,used_gpu_memory",
      "--format=csv,noheader,nounits",
    ]);
    const procs = [];
    for (const line of (pOut || "").trim().split(/\r?\n/)) {
      if (!line.trim()) continue;
      const parts = line.split(",").map((p) => p.trim());
      if (parts.length >= 3 && /^\d+$/.test(parts[0])) {
        const mem = num(parts[2]);
        if (mem == null || mem <= 0) continue;
        const rawName = parts[1] || "";
        const short = rawName.split(/[/\\]/).pop() || rawName;
        procs.push({
          pid: parseInt(parts[0], 10),
          name: short.slice(0, 64),
          mem_mib: mem,
        });
      }
    }
    procs.sort((a, b) => (b.mem_mib || 0) - (a.mem_mib || 0));
    if (gpus.length) gpus[0].processes = procs.slice(0, 12);
  } catch {
    /* best effort */
  }
  return gpus;
}

export async function collectProcessHighlights() {
  const nameKeys = [
    "llama-server",
    "lm studio",
    "lmstudio",
    "forge-conductor",
    "python",
  ];
  let list = [];
  try {
    list = await si.processes();
  } catch {
    return [];
  }
  const all = list.list || list || [];
  const out = [];
  for (const p of all) {
    const name = String(p.name || "").toLowerCase();
    const cmd = String(p.command || p.path || "").toLowerCase();
    const hit =
      nameKeys.some((k) => name.includes(k) || cmd.includes(k)) ||
      cmd.includes("forge-conductor") ||
      cmd.includes("llama-server") ||
      (name.includes("node") &&
        (cmd.includes("telemetry") || cmd.includes("server.js")));
    if (!hit) continue;

    // systeminformation: memRss is typically kB on Windows
    const mem = Number(p.memRss ?? p.mem_rss ?? 0) || 0;
    let rssGb = 0;
    if (mem > 0) {
      // Heuristic: values > 50e6 are almost certainly bytes
      rssGb = mem > 50_000_000 ? mem / 1024 ** 3 : mem / 1024 ** 2;
    }
    out.push({
      pid: p.pid,
      name: String(p.name || name).slice(0, 48),
      cpu_percent: Math.round((Number(p.cpu) || 0) * 10) / 10,
      rss_gb: Math.round(rssGb * 100) / 100,
    });
  }
  out.sort((a, b) => b.rss_gb - a.rss_gb);
  return out.slice(0, 20);
}

export async function collectSystem() {
  const [cpu, ram, disk, gpu, processes] = await Promise.all([
    collectCpu().catch((e) => ({ error: String(e), percent: 0 })),
    collectRam().catch((e) => ({ error: String(e), percent: 0 })),
    collectDisk().catch(() => []),
    collectGpu().catch(() => []),
    collectProcessHighlights().catch(() => []),
  ]);
  return {
    ts: Date.now() / 1000,
    cpu,
    ram,
    disk,
    gpu,
    processes,
  };
}

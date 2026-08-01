# Host metrics — Darwin API map

Forge Conductor host telemetry is **API-driven real-time**, not shell snapshots.

| Domain | Primary APIs | Collector |
|--------|--------------|-----------|
| Per-core CPU | Mach `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | `CPUCollector` |
| Host CPU ticks | Mach `host_statistics(HOST_CPU_LOAD_INFO)` | `CPUCollector` (fallback) |
| RAM | Mach `host_statistics64(HOST_VM_INFO64)` | `RAMCollector` |
| Process CPU/RSS | libproc `proc_pid_rusage(RUSAGE_INFO_V3)` | `ProcessMetricsCollector` |
| Process fallback | libproc `proc_pidinfo(PROC_PIDTASKINFO)` | `ProcessMetricsCollector` |
| Process threads | libproc `proc_pidinfo(PROC_PIDLISTTHREADS)` | `ProcessMetricsCollector` |
| Self threads | Mach `task_threads` / `thread_info` | `MachTaskThreadSampler` |
| Self RSS | Mach `task_info(MACH_TASK_BASIC_INFO)` | `MachTaskThreadSampler` |
| Disk I/O | IOKit + **IORegistry** on `IOBlockStorageDriver` | `DiskIOCollector` |
| GPU | IOKit + **IORegistry** on `IOAccelerator` / AGX / IOGPU | `GPUCollector` |
| Power | IOKit **IOPowerSources** (`IOPSCopyPowerSourcesInfo` …) | `PowerSourcesCollector` |

## Rules

1. **No** `/bin/ps`, **no** multi-second snapshot product clock.
2. Counter-based %/rates use **stored previous samples** (delta), never `Thread.sleep` on the sample path.
3. Heavy walks (IORegistry GPU/disk, process list, power) are **tiered** under `RealtimeMetricsEngine` so Mach CPU/RAM can run ~30 Hz.

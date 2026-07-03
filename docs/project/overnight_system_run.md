# Overnight System Run

Use this when you want to leave the machine running for 6-8 hours and keep a
record of system health plus optional project checks.

## Current System Snapshot

Captured on 2026-07-03 from this workspace.

| Area | Value |
|---|---|
| OS | Microsoft Windows 11 Pro 10.0.26200, 64-bit |
| CPU | AMD Ryzen 9 7945HX, 16 cores / 32 logical processors |
| Memory | 31.69 GiB physical RAM |
| GPU | NVIDIA GeForce RTX 4060 Laptop GPU, driver 32.0.16.1062 |
| Display adapter | Parsec Virtual Display Adapter |
| Disk C: | 1.82 TiB total, 667.33 GiB free |
| Disk D: | 953.88 GiB total, 590.62 GiB free |

## Recommended Overnight Command

From the repo root in PowerShell:

```powershell
.\scripts\overnight_system_run.ps1 -Hours 8 -IntervalSeconds 300 -RunBuildCheck -RunTests -RunMilestones -CommandEveryMinutes 60
```

For a lighter 6-hour monitoring-only run:

```powershell
.\scripts\overnight_system_run.ps1 -Hours 6 -IntervalSeconds 300
```

For a quick debug run:

```powershell
.\scripts\overnight_system_run.ps1 -Hours 0.01 -IntervalSeconds 5 -RunBuildCheck -RunMilestones -NoKeepAwake
```

## Output

Each run creates a timestamped folder under `pocket-agent/logs/`:

- `run.log` - human-readable progress.
- `system.json` - OS, CPU, GPU, disk, and tool snapshot.
- `metrics.csv` - compact CPU, memory, and disk samples.
- `samples.jsonl` - detailed resource samples, including top processes.
- `commands.log` - build/test/milestone command output.
- `SUMMARY.md` - final run summary.

The script keeps Windows awake by default for the current PowerShell process. Use
`-NoKeepAwake` only for short debug runs or when another tool is already handling
power management.

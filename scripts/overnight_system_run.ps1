param(
    [double]$Hours = 8,
    [int]$IntervalSeconds = 300,
    [int]$CommandEveryMinutes = 60,
    [switch]$RunBuildCheck,
    [switch]$RunTests,
    [switch]$RunMilestones,
    [switch]$NoKeepAwake
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Hours -le 0) {
    throw "Hours must be greater than 0."
}
if ($IntervalSeconds -lt 1) {
    throw "IntervalSeconds must be at least 1."
}
if ($CommandEveryMinutes -lt 1) {
    throw "CommandEveryMinutes must be at least 1."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$PocketRoot = Join-Path $RepoRoot "pocket-agent"
$RunId = Get-Date -Format "yyyyMMdd_HHmmss"
$RunDir = Join-Path $PocketRoot "logs\overnight_system_$RunId"
$MainLog = Join-Path $RunDir "run.log"
$MetricsCsv = Join-Path $RunDir "metrics.csv"
$SamplesJsonl = Join-Path $RunDir "samples.jsonl"
$CommandsLog = Join-Path $RunDir "commands.log"
$SummaryFile = Join-Path $RunDir "SUMMARY.md"

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
New-Item -ItemType File -Force -Path $CommandsLog | Out-Null

$CommandResults = New-Object System.Collections.Generic.List[object]
$KeepAwakeEnabled = $false

function Write-Log {
    param([string]$Message)
    $line = "{0} | {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $line | Tee-Object -FilePath $MainLog -Append
}

function Convert-BytesToGiB {
    param([Nullable[Int64]]$Bytes)
    if ($null -eq $Bytes) {
        return $null
    }
    return [math]::Round($Bytes / 1GB, 2)
}

function Get-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Get-GpuText {
    $nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($null -eq $nvidia) {
        return @()
    }

    try {
        return @(& $nvidia.Source --query-gpu=name,driver_version,memory.total,memory.used,temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>$null)
    }
    catch {
        return @("nvidia-smi failed: $($_.Exception.Message)")
    }
}

function Get-SystemSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor
    $gpu = Get-CimInstance Win32_VideoController
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"

    return [ordered]@{
        captured_at = (Get-Date).ToString("o")
        repo_root = $RepoRoot
        pocket_root = $PocketRoot
        os = $os | Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime
        computer = $computer | Select-Object Manufacturer, Model, SystemType, @{Name = "TotalPhysicalMemoryGiB"; Expression = { Convert-BytesToGiB $_.TotalPhysicalMemory } }
        cpu = $cpu | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
        gpu = $gpu | Select-Object Name, @{Name = "AdapterRAMGiB"; Expression = { Convert-BytesToGiB $_.AdapterRAM } }, DriverVersion
        disks = $disks | Select-Object DeviceID, VolumeName, @{Name = "SizeGiB"; Expression = { Convert-BytesToGiB $_.Size } }, @{Name = "FreeGiB"; Expression = { Convert-BytesToGiB $_.FreeSpace } }
        commands = [ordered]@{
            git = Get-CommandPath "git"
            bash = Get-CommandPath "bash"
            python = Get-CommandPath "python"
            pwsh = Get-CommandPath "pwsh"
            powershell = Get-CommandPath "powershell"
            nvidia_smi = Get-CommandPath "nvidia-smi"
        }
    }
}

function Get-ResourceSample {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"
    $totalMemoryBytes = [int64]$os.TotalVisibleMemorySize * 1024
    $freeMemoryBytes = [int64]$os.FreePhysicalMemory * 1024
    $usedMemoryBytes = $totalMemoryBytes - $freeMemoryBytes
    $loadAverage = ($cpu | Measure-Object -Property LoadPercentage -Average).Average

    $topProcesses = Get-Process |
        Sort-Object -Property CPU -Descending |
        Select-Object -First 10 `
            @{Name = "name"; Expression = { $_.ProcessName } },
            Id,
            @{Name = "cpu_seconds"; Expression = { if ($null -eq $_.CPU) { 0 } else { [math]::Round($_.CPU, 1) } } },
            @{Name = "private_memory_mib"; Expression = { [math]::Round($_.PrivateMemorySize64 / 1MB, 1) } },
            @{Name = "working_set_mib"; Expression = { [math]::Round($_.WorkingSet64 / 1MB, 1) } }

    return [ordered]@{
        timestamp = (Get-Date).ToString("o")
        cpu_load_percent = [math]::Round($loadAverage, 1)
        memory = [ordered]@{
            used_gib = Convert-BytesToGiB $usedMemoryBytes
            free_gib = Convert-BytesToGiB $freeMemoryBytes
            total_gib = Convert-BytesToGiB $totalMemoryBytes
        }
        disks = $disks | Select-Object DeviceID, @{Name = "free_gib"; Expression = { Convert-BytesToGiB $_.FreeSpace } }, @{Name = "size_gib"; Expression = { Convert-BytesToGiB $_.Size } }
        gpu = Get-GpuText
        top_processes = $topProcesses
    }
}

function Write-MetricsHeader {
    "timestamp,cpu_load_percent,memory_used_gib,memory_free_gib,c_free_gib,d_free_gib" |
        Set-Content -Encoding UTF8 -Path $MetricsCsv
}

function Add-MetricsRow {
    param([System.Collections.IDictionary]$Sample)

    $cFree = ""
    $dFree = ""
    foreach ($disk in $Sample.disks) {
        if ($disk.DeviceID -eq "C:") {
            $cFree = $disk.free_gib
        }
        if ($disk.DeviceID -eq "D:") {
            $dFree = $disk.free_gib
        }
    }

    "{0},{1},{2},{3},{4},{5}" -f $Sample.timestamp, $Sample.cpu_load_percent, $Sample.memory.used_gib, $Sample.memory.free_gib, $cFree, $dFree |
        Add-Content -Encoding UTF8 -Path $MetricsCsv
}

function Invoke-LoggedCommand {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )

    $started = Get-Date
    $oldLocation = Get-Location
    $oldEnv = @{}
    Write-Log "command start: $Name"
    "===== $($started.ToString("o")) | START | $Name =====" | Add-Content -Encoding UTF8 -Path $CommandsLog

    try {
        Set-Location $WorkingDirectory
        foreach ($key in $Environment.Keys) {
            $oldEnv[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
            [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
        }

        $output = & $FilePath @Arguments 2>&1
        $exitCode = if ($null -eq $global:LASTEXITCODE) { 0 } else { $global:LASTEXITCODE }
        $output | Tee-Object -FilePath $CommandsLog -Append
    }
    catch {
        $exitCode = 1
        "ERROR: $($_.Exception.Message)" | Tee-Object -FilePath $CommandsLog -Append
    }
    finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $oldEnv[$key], "Process")
        }
        Set-Location $oldLocation
    }

    $ended = Get-Date
    $seconds = [math]::Round(($ended - $started).TotalSeconds, 2)
    "===== $($ended.ToString("o")) | END | $Name | exit=$exitCode | seconds=$seconds =====" |
        Add-Content -Encoding UTF8 -Path $CommandsLog
    Write-Log "command end: $Name exit=$exitCode seconds=$seconds"

    $CommandResults.Add([ordered]@{
        name = $Name
        exit_code = $exitCode
        started_at = $started.ToString("o")
        ended_at = $ended.ToString("o")
        seconds = $seconds
    }) | Out-Null

    return $exitCode
}

function Enable-KeepAwake {
    if ($NoKeepAwake) {
        Write-Log "keep-awake disabled by -NoKeepAwake"
        return
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Write-Log "keep-awake skipped: non-Windows platform"
        return
    }

    try {
        if ($null -eq ("OvernightSleepGuard" -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class OvernightSleepGuard {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern UInt32 SetThreadExecutionState(UInt32 esFlags);
}
"@ -ErrorAction Stop
        }
        [OvernightSleepGuard]::SetThreadExecutionState(([uint32]2147483648 -bor [uint32]1)) | Out-Null
        $script:KeepAwakeEnabled = $true
        Write-Log "keep-awake enabled for this PowerShell process"
    }
    catch {
        Write-Log "keep-awake setup failed: $($_.Exception.Message)"
    }
}

function Disable-KeepAwake {
    if ($KeepAwakeEnabled) {
        [OvernightSleepGuard]::SetThreadExecutionState([uint32]2147483648) | Out-Null
        Write-Log "keep-awake released"
    }
}

function Write-Summary {
    param(
        [datetime]$StartedAt,
        [datetime]$EndedAt,
        [int]$SampleCount
    )

    $requiredFailures = @($CommandResults | Where-Object { $_.exit_code -ne 0 })
    $startedIso = $StartedAt.ToString('o')
    $endedIso = $EndedAt.ToString('o')
    $durationSeconds = [math]::Round(($EndedAt - $StartedAt).TotalSeconds, 2)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Overnight System Run") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add(('- Started: `{0}`' -f $startedIso)) | Out-Null
    $lines.Add(('- Ended: `{0}`' -f $endedIso)) | Out-Null
    $lines.Add(('- Duration seconds: `{0}`' -f $durationSeconds)) | Out-Null
    $lines.Add(('- Samples: `{0}`' -f $SampleCount)) | Out-Null
    $lines.Add(('- Command failures: `{0}`' -f $requiredFailures.Count)) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Files") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add('- `run.log` - human-readable run log') | Out-Null
    $lines.Add('- `system.json` - system and tool snapshot') | Out-Null
    $lines.Add('- `metrics.csv` - compact resource samples') | Out-Null
    $lines.Add('- `samples.jsonl` - detailed resource samples') | Out-Null
    $lines.Add('- `commands.log` - build/test/milestone command output') | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Commands") | Out-Null
    $lines.Add("") | Out-Null
    if ($CommandResults.Count -eq 0) {
        $lines.Add("No optional commands were enabled.") | Out-Null
    }
    else {
        $lines.Add("| Command | Exit | Seconds | Started |") | Out-Null
        $lines.Add("|---|---:|---:|---|") | Out-Null
        foreach ($result in $CommandResults) {
            $lines.Add(('| {0} | {1} | {2} | `{3}` |' -f $result.name, $result.exit_code, $result.seconds, $result.started_at)) | Out-Null
        }
    }

    $lines | Set-Content -Encoding UTF8 -Path $SummaryFile
}

$StartedAt = Get-Date
$EndAt = $StartedAt.AddHours($Hours)
$NextCommandAt = $StartedAt
$SampleCount = 0

try {
    Write-Log "overnight run started"
    Write-Log "repo root: $RepoRoot"
    Write-Log "run dir: $RunDir"
    Write-Log "duration hours: $Hours"
    Write-Log "sample interval seconds: $IntervalSeconds"
    Enable-KeepAwake

    Get-SystemSnapshot | ConvertTo-Json -Depth 8 |
        Set-Content -Encoding UTF8 -Path (Join-Path $RunDir "system.json")
    Write-MetricsHeader

    if ($RunBuildCheck) {
        Invoke-LoggedCommand -Name "build.cmd --check" -FilePath (Join-Path $RepoRoot "build.cmd") -Arguments @("--check") -WorkingDirectory $RepoRoot | Out-Null
    }

    while ((Get-Date) -lt $EndAt) {
        $SampleCount += 1
        $sample = Get-ResourceSample
        Add-MetricsRow -Sample $sample
        $sample | ConvertTo-Json -Depth 8 -Compress |
            Add-Content -Encoding UTF8 -Path $SamplesJsonl

        Write-Log ("sample {0}: cpu={1}% mem={2}/{3} GiB freeD={4} GiB" -f `
            $SampleCount,
            $sample.cpu_load_percent,
            $sample.memory.used_gib,
            $sample.memory.total_gib,
            (($sample.disks | Where-Object { $_.DeviceID -eq "D:" } | Select-Object -First 1).free_gib))

        if (($RunTests -or $RunMilestones) -and (Get-Date) -ge $NextCommandAt) {
            $python = Join-Path $PocketRoot ".venv\Scripts\python.exe"
            if (-not (Test-Path $python)) {
                $python = "python"
            }

            if ($RunTests) {
                Invoke-LoggedCommand -Name "pytest -q" -FilePath $python -Arguments @("-m", "pytest", "-q") -WorkingDirectory $PocketRoot | Out-Null
            }
            if ($RunMilestones) {
                Invoke-LoggedCommand -Name "verify_milestones.py mock" -FilePath $python -Arguments @("verify_milestones.py") -WorkingDirectory $PocketRoot -Environment @{ POCKET_FORCE_MOCK = "1" } | Out-Null
            }

            $NextCommandAt = (Get-Date).AddMinutes($CommandEveryMinutes)
        }

        $remaining = ($EndAt - (Get-Date)).TotalSeconds
        if ($remaining -gt 0) {
            Start-Sleep -Seconds ([int][Math]::Min($IntervalSeconds, [Math]::Max(1, $remaining)))
        }
    }
}
finally {
    $EndedAt = Get-Date
    Disable-KeepAwake
    Write-Summary -StartedAt $StartedAt -EndedAt $EndedAt -SampleCount $SampleCount
    Write-Log "overnight run finished"
    Write-Log "summary: $SummaryFile"
}

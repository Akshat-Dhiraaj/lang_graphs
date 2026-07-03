param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$Foreground,
    [switch]$Stop
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildTmp = Join-Path $Root "pocket-agent\.build_tmp"
$LogDir = Join-Path $Root "pocket-agent\logs"
$ServerPath = Join-Path $Root "sandbox\server.py"
$PidFile = Join-Path $BuildTmp "sandbox_server.pid"
$Url = "http://127.0.0.1:$Port"

New-Item -ItemType Directory -Force -Path $BuildTmp, $LogDir | Out-Null

function Test-LocalPort {
    param([int]$TestPort)
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect("127.0.0.1", $TestPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(250)) {
            return $false
        }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) {
            $client.Dispose()
        }
    }
}

function Test-SandboxEndpoint {
    try {
        $resp = Invoke-WebRequest -Uri "$Url/api/status" -UseBasicParsing -TimeoutSec 5
        return ($resp.Content -like "*lmstudio*") -and ($resp.Content -like "*git*")
    } catch {
        return $false
    }
}

function Stop-Sandbox {
    if (-not (Test-Path $PidFile)) {
        Write-Host "No sandbox PID file found."
        return
    }
    $rawPid = (Get-Content -Path $PidFile -Raw).Trim()
    if (-not $rawPid) {
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Sandbox PID file was empty; removed it."
        return
    }
    $proc = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
    if ($proc) {
        Stop-Process -Id $proc.Id -Force
        Write-Host "Stopped sandbox server PID $($proc.Id)."
    } else {
        Write-Host "Sandbox server PID $rawPid was not running."
    }
    Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
}

function Resolve-Python {
    $venvPython = Join-Path $Root "pocket-agent\.venv\Scripts\python.exe"
    if (Test-Path $venvPython) {
        return @{ Path = $venvPython; Args = @() }
    }

    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        return @{ Path = $pyLauncher.Source; Args = @("-3") }
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        return @{ Path = $pythonCmd.Source; Args = @() }
    }

    throw "Python was not found. Run .\build.cmd once, or install Python 3.10+."
}

if ($Stop) {
    Stop-Sandbox
    return
}

if (-not (Test-Path $ServerPath)) {
    throw "Sandbox server was not found at $ServerPath."
}

if (Test-LocalPort -TestPort $Port) {
    if (Test-SandboxEndpoint) {
        Write-Host "Sandbox already appears to be running at $Url"
        if (-not $NoBrowser) {
            Start-Process $Url
        }
        return
    }
    throw "Port $Port is already in use by another service. Retry with -Port <free-port>."
}

$Python = Resolve-Python
$PythonPath = $Python["Path"]
$PythonArgs = $Python["Args"]
$ServerArgs = @($PythonArgs + @("-u", $ServerPath))
$env:POCKET_SANDBOX_ROOT = $Root
$env:POCKET_SANDBOX_PORT = [string]$Port
$env:PYTHONIOENCODING = "utf-8"

if ($Foreground) {
    Write-Host "Starting Pocket Agent sandbox in foreground at $Url"
    if (-not $NoBrowser) {
        Start-Process $Url
    }
    & $PythonPath @ServerArgs
    return
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutLog = Join-Path $LogDir "sandbox_$timestamp.out.log"
$ErrLog = Join-Path $LogDir "sandbox_$timestamp.err.log"
$proc = Start-Process `
    -FilePath $PythonPath `
    -ArgumentList $ServerArgs `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $OutLog `
    -RedirectStandardError $ErrLog `
    -PassThru

Set-Content -Path $PidFile -Value ([string]$proc.Id) -Encoding ascii

$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if (Test-SandboxEndpoint) {
        Write-Host "Sandbox running at $Url"
        Write-Host "PID: $($proc.Id)"
        Write-Host "Logs: $OutLog"
        if (-not $NoBrowser) {
            Start-Process $Url
        }
        return
    }
    Start-Sleep -Milliseconds 300
}

if ($proc.HasExited) {
    throw "Sandbox process exited early. Check $ErrLog"
}

throw "Sandbox process started but did not answer at $Url. Check $OutLog and $ErrLog"

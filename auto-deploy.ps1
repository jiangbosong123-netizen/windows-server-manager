$ErrorActionPreference = "Continue"
$ManagerRoot = $PSScriptRoot
$ServerRoot = Split-Path -Parent $ManagerRoot
$LogDirectory = Join-Path $ManagerRoot "logs"
$PidFile = Join-Path $LogDirectory "auto-deploy.pid"
$PollSeconds = 300
$env:GIT_TERMINAL_PROMPT = "0"

Import-Module (Join-Path $ManagerRoot "lib\DeploymentManager.psm1") -Force
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$watcherName = if ($env:OS -eq "Windows_NT") {
    "Global\WindowsServerManager-AutoDeploy"
}
else { "WindowsServerManager-AutoDeploy" }
$watcherMutex = New-Object System.Threading.Mutex($false, $watcherName)
$acquired = $false
try { $acquired = $watcherMutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { $watcherMutex.Dispose(); exit 0 }

function Test-DockerReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    return $LASTEXITCODE -eq 0
}

try {
    Set-Content -LiteralPath $PidFile -Value $PID
    Write-ManagerLog $ManagerRoot "manager" "watcher_started" "poll_seconds=$PollSeconds"
    while ($true) {
        try {
            $projects = @(Read-ProjectRegistry $ManagerRoot $ServerRoot)
            if (Test-DockerReady) {
                foreach ($project in $projects) {
                    $result = Invoke-ProjectCycle $project $ManagerRoot
                    if ($result.Status -notin @("healthy", "backoff", "locked", "waiting_ci")) {
                        Write-ManagerLog $ManagerRoot $project.id "cycle" "status=$($result.Status)"
                    }
                }
            }
            else {
                Write-ManagerLog $ManagerRoot "manager" "docker_unavailable" "deployment cycle skipped"
            }
        }
        catch {
            Write-ManagerLog $ManagerRoot "manager" "cycle_error" $_.Exception.Message
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    Remove-Item -Force -LiteralPath $PidFile -ErrorAction SilentlyContinue
    try { $watcherMutex.ReleaseMutex() } catch { }
    $watcherMutex.Dispose()
}

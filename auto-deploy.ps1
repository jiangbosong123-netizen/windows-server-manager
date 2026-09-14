$ErrorActionPreference = "Continue"
$ServerRoot = Split-Path -Parent $PSScriptRoot
$LogDirectory = Join-Path $PSScriptRoot "logs"
$LogFile = Join-Path $LogDirectory "auto-deploy.log"
$PidFile = Join-Path $LogDirectory "auto-deploy.pid"
$PollSeconds = 300
$env:GIT_TERMINAL_PROMPT = "0"

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$mutex = New-Object System.Threading.Mutex($false, "Local\WindowsServerManagerAutoDeploy")
$acquired = $false
try { $acquired = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { exit 0 }

function Write-Log([string]$Message) {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 2MB) {
        Move-Item -Force $LogFile ($LogFile + ".old")
    }
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
}

function Get-Projects {
    return @(Get-ChildItem -Path $ServerRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -ne $PSScriptRoot -and (Test-Path (Join-Path $_.FullName ".git")) -and
            ((Test-Path (Join-Path $_.FullName "compose.yaml")) -or
             (Test-Path (Join-Path $_.FullName "compose.yml")) -or
             (Test-Path (Join-Path $_.FullName "docker-compose.yml")) -or
             (Test-Path (Join-Path $_.FullName "docker-compose.yaml")))
        } | Sort-Object Name)
}

function Docker-Ready {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    & docker info *> $null
    return $LASTEXITCODE -eq 0
}

function Update-IfNeeded([System.IO.DirectoryInfo]$Project) {
    $changes = @(& git -C $Project.FullName status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0 -or $changes.Count -gt 0) {
        Write-Log "[$($Project.Name)] skipped: local changes or Git status failure"
        return
    }
    $branch = (& git -C $Project.FullName branch --show-current 2>&1).Trim()
    if (-not $branch) { return }

    $fetchOutput = @(& git -C $Project.FullName fetch --quiet origin $branch 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[$($Project.Name)] fetch failed: $($fetchOutput -join ' ')"
        return
    }
    $localRevision = (& git -C $Project.FullName rev-parse HEAD).Trim()
    $remoteRevision = (& git -C $Project.FullName rev-parse "origin/$branch").Trim()
    if (-not $remoteRevision -or $localRevision -eq $remoteRevision) { return }

    & git -C $Project.FullName merge-base --is-ancestor $localRevision $remoteRevision
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[$($Project.Name)] skipped: local branch is not a fast-forward of origin/$branch"
        return
    }
    $pullOutput = @(& git -C $Project.FullName pull --ff-only origin $branch 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-Log "[$($Project.Name)] pull failed: $($pullOutput -join ' ')"
        return
    }

    $previousVersion = $env:APP_VERSION
    $env:APP_VERSION = $remoteRevision.Substring(0, [Math]::Min(12, $remoteRevision.Length))
    Push-Location $Project.FullName
    try {
        $deployOutput = @(& docker compose up -d --build --remove-orphans 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Write-Log "[$($Project.Name)] deployed $env:APP_VERSION"
        }
        else {
            Write-Log "[$($Project.Name)] deploy failed: $($deployOutput -join ' ')"
        }
    }
    finally {
        Pop-Location
        $env:APP_VERSION = $previousVersion
    }
}

try {
    Set-Content -Path $PidFile -Value $PID
    Write-Log "automatic deployment watcher started"
    while ($true) {
        if (Docker-Ready) {
            foreach ($project in (Get-Projects)) { Update-IfNeeded $project }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    Remove-Item -Force $PidFile -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Windows Server Manager"
$ManagerRoot = $PSScriptRoot
$ServerRoot = Split-Path -Parent $ManagerRoot

Import-Module (Join-Path $ManagerRoot "lib\DeploymentManager.psm1") -Force

function Wait-ForUser {
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Get-Projects {
    try { return @(Read-ProjectRegistry $ManagerRoot $ServerRoot) }
    catch {
        Write-Host "Project registry error: $($_.Exception.Message)" -ForegroundColor Red
        return @()
    }
}

function Select-Project {
    $projects = @(Get-Projects)
    if ($projects.Count -eq 0) {
        Write-Host "No enabled projects are registered in projects.json" -ForegroundColor Yellow
        return $null
    }
    Write-Host ""
    for ($i = 0; $i -lt $projects.Count; $i++) {
        $state = Read-DeploymentState $ManagerRoot $projects[$i].id
        Write-Host "  $($i + 1). $($projects[$i].id) [$($state.status)]"
    }
    Write-Host "  0. Cancel"
    $answer = Read-Host "Select a project"
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number)) { return $null }
    if ($number -lt 1 -or $number -gt $projects.Count) { return $null }
    return $projects[$number - 1]
}

function Ensure-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "Docker is not installed or is not available in PATH." -ForegroundColor Red
        return $false
    }
    & docker info *> $null
    if ($LASTEXITCODE -eq 0) { return $true }
    $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path -LiteralPath $desktop) {
        Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow
        Start-Process $desktop
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            Start-Sleep -Seconds 2
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) { return $true }
        }
    }
    Write-Host "Docker is not ready. Open Docker Desktop and try again." -ForegroundColor Red
    return $false
}

function Invoke-LockedCompose([object]$Project, [string[]]$Arguments) {
    $mutex = Enter-ProjectMutex $Project.id
    if ($null -eq $mutex) {
        Write-Host "Another automatic or manual action is running for $($Project.id)." -ForegroundColor Yellow
        return
    }
    try {
        $compose = Join-Path $Project.fullPath $Project.composeFile
        $state = Read-DeploymentState $ManagerRoot $Project.id
        $override = Get-HealthyOverridePath $ManagerRoot $Project $state
        $revision = if ($state.healthySha) { [string]$state.healthySha } else {
            (& git -C $Project.fullPath rev-parse HEAD 2>$null).Trim()
        }
        $previousVersion = $env:APP_VERSION
        if ($revision) { $env:APP_VERSION = $revision }
        Write-Host ""
        Write-Host "[$($Project.id)] docker compose $($Arguments -join ' ')" -ForegroundColor Cyan
        Push-Location $Project.fullPath
        try {
            $composeArguments = @("compose", "-p", $Project.composeProject, "-f", $compose)
            if ($override) { $composeArguments += @("-f", $override) }
            & docker @composeArguments @Arguments
        }
        finally { Pop-Location; $env:APP_VERSION = $previousVersion }
    }
    finally { Exit-ProjectMutex $mutex }
}

function Show-AllStatus {
    $projects = @(Get-Projects)
    if ($projects.Count -eq 0) { return }
    foreach ($project in $projects) {
        $state = Read-DeploymentState $ManagerRoot $project.id
        Write-Host ""
        Write-Host "[$($project.id)] deploy=$($state.status) desired=$($state.desiredSha) healthy=$($state.healthySha)" -ForegroundColor Cyan
        $compose = Join-Path $project.fullPath $project.composeFile
        & docker compose -p $project.composeProject -f $compose ps
    }
}

function Update-Project([object]$Project) {
    Write-Host "Checking fixed main SHA and required GitHub checks for $($Project.id)..." -ForegroundColor Cyan
    try {
        $result = Invoke-ProjectCycle $Project $ManagerRoot -ForceRetry
        $color = if ($result.Status -eq "healthy") { "Green" } else { "Yellow" }
        Write-Host "Deployment status: $($result.Status)" -ForegroundColor $color
        if ($result.State.lastError) { Write-Host "Detail: $($result.State.lastError)" -ForegroundColor Yellow }
    }
    catch { Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red }
}

function Get-AutoDeployShortcut {
    return Join-Path ([Environment]::GetFolderPath("Startup")) "Windows Server Auto Deploy.lnk"
}

function Test-AutoDeployRunning {
    $pidFile = Join-Path $ManagerRoot "logs\auto-deploy.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return $false }
    $watcherPid = 0
    if (-not [int]::TryParse((Get-Content $pidFile -ErrorAction SilentlyContinue), [ref]$watcherPid)) {
        return $false
    }
    return $null -ne (Get-Process -Id $watcherPid -ErrorAction SilentlyContinue)
}

function Enable-AutoDeploy {
    $shortcutPath = Get-AutoDeployShortcut
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ManagerRoot\auto-deploy.ps1`""
    $shortcut.WorkingDirectory = $ManagerRoot
    $shortcut.Save()
    if (-not (Test-AutoDeployRunning)) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ManagerRoot\auto-deploy.ps1`"")
        Start-Sleep -Seconds 2
    }
    Write-Host "Automatic deployment is enabled." -ForegroundColor Green
    Write-Host "Only registered main branches with successful required checks can deploy."
}

function Disable-AutoDeploy {
    Remove-Item -Force -LiteralPath (Get-AutoDeployShortcut) -ErrorAction SilentlyContinue
    $pidFile = Join-Path $ManagerRoot "logs\auto-deploy.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $watcherPid = 0
        if ([int]::TryParse((Get-Content $pidFile -ErrorAction SilentlyContinue), [ref]$watcherPid)) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$watcherPid" -ErrorAction SilentlyContinue
            if ($process.CommandLine -like "*auto-deploy.ps1*") {
                Stop-Process -Id $watcherPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host "Automatic deployment is disabled." -ForegroundColor Yellow
}

if (-not (Ensure-Docker)) { Wait-ForUser; exit 1 }

while ($true) {
    Clear-Host
    Write-Host "WINDOWS SERVER MANAGER" -ForegroundColor Green
    Write-Host "Registry: $ManagerRoot\projects.json"
    Write-Host ""
    Write-Host "  1. Show registered project and deployment status"
    Write-Host "  2. Check and deploy a project"
    Write-Host "  3. Start a project"
    Write-Host "  4. Stop a project"
    Write-Host "  5. Restart a project"
    Write-Host "  6. Show recent logs"
    Write-Host "  7. Check and deploy all projects"
    Write-Host "  8. Enable automatic deployment"
    Write-Host "  9. Disable automatic deployment"
    $autoState = if (Test-AutoDeployRunning) { "enabled and running" } elseif (Test-Path (Get-AutoDeployShortcut)) { "enabled; starts at next login" } else { "disabled" }
    Write-Host "     Automatic deployment: $autoState" -ForegroundColor DarkGray
    Write-Host "  0. Exit"
    Write-Host ""
    $choice = Read-Host "Choose an action"
    switch ($choice) {
        "1" { Show-AllStatus; Wait-ForUser }
        "2" { $project = Select-Project; if ($project) { Update-Project $project; Wait-ForUser } }
        "3" { $project = Select-Project; if ($project) { Invoke-LockedCompose $project @("up", "-d", "--no-build"); Wait-ForUser } }
        "4" { $project = Select-Project; if ($project) { Invoke-LockedCompose $project @("stop"); Wait-ForUser } }
        "5" { $project = Select-Project; if ($project) { Invoke-LockedCompose $project @("restart"); Wait-ForUser } }
        "6" { $project = Select-Project; if ($project) { Invoke-LockedCompose $project @("logs", "--tail", "100"); Wait-ForUser } }
        "7" { foreach ($project in (Get-Projects)) { Update-Project $project }; Wait-ForUser }
        "8" { Enable-AutoDeploy; Wait-ForUser }
        "9" { Disable-AutoDeploy; Wait-ForUser }
        "0" { exit 0 }
        default { }
    }
}

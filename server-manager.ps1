$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Windows Server Manager"
$ServerRoot = Split-Path -Parent $PSScriptRoot

function Wait-ForUser {
    Write-Host ""
    Read-Host "Press Enter to continue"
}

function Get-ComposeFile([string]$ProjectPath) {
    foreach ($name in @("compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml")) {
        $candidate = Join-Path $ProjectPath $name
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Get-Projects {
    return @(Get-ChildItem -Path $ServerRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $PSScriptRoot -and (Get-ComposeFile $_.FullName) } |
        Sort-Object Name)
}

function Invoke-Compose([System.IO.DirectoryInfo]$Project, [string[]]$Arguments) {
    Write-Host ""
    Write-Host "[$($Project.Name)] docker compose $($Arguments -join ' ')" -ForegroundColor Cyan
    $previousVersion = $env:APP_VERSION
    $gitDirectory = Join-Path $Project.FullName ".git"
    if (Test-Path $gitDirectory) {
        $revision = (& git -C $Project.FullName rev-parse --short=12 HEAD).Trim()
        if ($LASTEXITCODE -eq 0 -and $revision) { $env:APP_VERSION = $revision }
    }
    Push-Location $Project.FullName
    try {
        & docker compose @Arguments
    }
    finally {
        Pop-Location
        $env:APP_VERSION = $previousVersion
    }
}

function Ensure-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "Docker is not installed or is not available in PATH." -ForegroundColor Red
        return $false
    }

    & docker info *> $null
    if ($LASTEXITCODE -eq 0) { return $true }

    $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $desktop) {
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

function Select-Project {
    $projects = @(Get-Projects)
    if ($projects.Count -eq 0) {
        Write-Host "No Docker Compose projects were found under $ServerRoot" -ForegroundColor Yellow
        return $null
    }

    Write-Host ""
    for ($i = 0; $i -lt $projects.Count; $i++) {
        Write-Host "  $($i + 1). $($projects[$i].Name)"
    }
    Write-Host "  0. Cancel"
    $answer = Read-Host "Select a project"
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number)) { return $null }
    if ($number -lt 1 -or $number -gt $projects.Count) { return $null }
    return $projects[$number - 1]
}

function Show-AllStatus {
    $projects = @(Get-Projects)
    if ($projects.Count -eq 0) {
        Write-Host "No Docker Compose projects were found under $ServerRoot" -ForegroundColor Yellow
        return
    }
    foreach ($project in $projects) {
        Invoke-Compose $project @("ps")
    }
}

function Update-Project([System.IO.DirectoryInfo]$Project) {
    $gitDirectory = Join-Path $Project.FullName ".git"
    if (Test-Path $gitDirectory) {
        $changes = @(& git -C $Project.FullName status --porcelain)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Git status failed. Update cancelled." -ForegroundColor Red
            return
        }
        if ($changes.Count -gt 0) {
            Write-Host "Local code changes were found. Update cancelled to protect them:" -ForegroundColor Yellow
            $changes | ForEach-Object { Write-Host "  $_" }
            return
        }

        $branch = (& git -C $Project.FullName branch --show-current).Trim()
        if (-not $branch) {
            Write-Host "The project is not on a Git branch. Update cancelled." -ForegroundColor Red
            return
        }
        Write-Host "Pulling $($Project.Name) branch $branch..." -ForegroundColor Cyan
        & git -C $Project.FullName pull --ff-only origin $branch
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Git pull failed. Existing containers were left unchanged." -ForegroundColor Red
            return
        }
    }
    else {
        Write-Host "This folder is not a Git clone; rebuilding its current files." -ForegroundColor Yellow
    }

    Invoke-Compose $Project @("up", "-d", "--build", "--remove-orphans")
}

function Get-AutoDeployShortcut {
    return Join-Path ([Environment]::GetFolderPath("Startup")) "Windows Server Auto Deploy.lnk"
}

function Test-AutoDeployRunning {
    $pidFile = Join-Path $PSScriptRoot "logs\auto-deploy.pid"
    if (-not (Test-Path $pidFile)) { return $false }
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
    $shortcut.Arguments = "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSScriptRoot\auto-deploy.ps1`""
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Save()
    if (-not (Test-AutoDeployRunning)) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSScriptRoot\auto-deploy.ps1`"")
        Start-Sleep -Seconds 2
    }
    Write-Host "Automatic deployment is enabled." -ForegroundColor Green
    Write-Host "GitHub is checked every 5 minutes while this Windows user is signed in."
}

function Disable-AutoDeploy {
    Remove-Item -Force (Get-AutoDeployShortcut) -ErrorAction SilentlyContinue
    $pidFile = Join-Path $PSScriptRoot "logs\auto-deploy.pid"
    if (Test-Path $pidFile) {
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

if (-not (Ensure-Docker)) {
    Wait-ForUser
    exit 1
}

while ($true) {
    Clear-Host
    Write-Host "WINDOWS SERVER MANAGER" -ForegroundColor Green
    Write-Host "Projects folder: $ServerRoot"
    Write-Host ""
    Write-Host "  1. Show all project status"
    Write-Host "  2. Update and deploy a project"
    Write-Host "  3. Start a project"
    Write-Host "  4. Stop a project"
    Write-Host "  5. Restart a project"
    Write-Host "  6. Show recent logs"
    Write-Host "  7. Update and deploy all projects"
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
        "3" { $project = Select-Project; if ($project) { Invoke-Compose $project @("up", "-d"); Wait-ForUser } }
        "4" { $project = Select-Project; if ($project) { Invoke-Compose $project @("stop"); Wait-ForUser } }
        "5" { $project = Select-Project; if ($project) { Invoke-Compose $project @("restart"); Wait-ForUser } }
        "6" { $project = Select-Project; if ($project) { Invoke-Compose $project @("logs", "--tail", "100"); Wait-ForUser } }
        "7" { foreach ($project in (Get-Projects)) { Update-Project $project }; Wait-ForUser }
        "8" { Enable-AutoDeploy; Wait-ForUser }
        "9" { Disable-AutoDeploy; Wait-ForUser }
        "0" { exit 0 }
        default { }
    }
}

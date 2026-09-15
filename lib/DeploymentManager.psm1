Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-UtcNow {
    return (Get-Date).ToUniversalTime()
}

function ConvertTo-SafeName([string]$Value) {
    return ([regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9_.-]', '-')).Trim('-')
}

function Get-StatePath([string]$ManagerRoot, [string]$ProjectId) {
    return Join-Path (Join-Path $ManagerRoot "state") "$ProjectId.json"
}

function New-DeploymentState([string]$ProjectId) {
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        projectId = $ProjectId
        status = "never_deployed"
        desiredSha = $null
        deployedSha = $null
        healthySha = $null
        previousHealthySha = $null
        failureCount = 0
        nextRetryAt = $null
        lastAttemptAt = $null
        lastHealthyAt = $null
        lastError = $null
    }
}

function Read-DeploymentState([string]$ManagerRoot, [string]$ProjectId) {
    $path = Get-StatePath $ManagerRoot $ProjectId
    if (-not (Test-Path -LiteralPath $path)) {
        return New-DeploymentState $ProjectId
    }
    try {
        $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Deployment state is unreadable for $ProjectId`: $($_.Exception.Message)"
    }
    if ($state.schemaVersion -ne 1 -or $state.projectId -ne $ProjectId) {
        throw "Deployment state has an unsupported identity or schema for $ProjectId"
    }
    return $state
}

function Write-DeploymentState([string]$ManagerRoot, [object]$State) {
    $directory = Join-Path $ManagerRoot "state"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $path = Get-StatePath $ManagerRoot $State.projectId
    $temporary = "$path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    $backup = "$path.replace-backup"
    try {
        $json = $State | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $path) {
            [IO.File]::Replace($temporary, $path, $backup, $true)
            Remove-Item -Force -LiteralPath $backup -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($temporary, $path)
        }
    }
    finally {
        Remove-Item -Force -LiteralPath $temporary -ErrorAction SilentlyContinue
    }
}

function ConvertTo-SafeMessage([string]$Message) {
    $safe = ($Message -replace '[\r\n]+', ' ').Trim()
    $safe = $safe -replace '(?i)\bauthorization\s*[:=]\s*(?:bearer\s+)?[^\s,;]+', 'authorization=[redacted]'
    $safe = $safe -replace '(?i)\b(token|password|api[_-]?key)\s*[:=]\s*[^\s,;]+', '$1=[redacted]'
    if ($safe.Length -gt 2000) { $safe = $safe.Substring(0, 2000) + '...[truncated]' }
    return $safe
}

function Write-ManagerLog(
    [string]$ManagerRoot,
    [string]$ProjectId,
    [string]$Event,
    [string]$Message
) {
    $directory = Join-Path $ManagerRoot "logs"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $path = Join-Path $directory "auto-deploy.log"
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 2MB) {
        Move-Item -Force -LiteralPath $path -Destination "$path.old"
    }
    $safeMessage = ConvertTo-SafeMessage ([string]$Message)
    Add-Content -LiteralPath $path -Encoding UTF8 -Value (
        "{0} project={1} event={2} {3}" -f (Get-UtcNow).ToString('o'), $ProjectId, $Event, $safeMessage
    )
}

function Get-RequiredCheckGate([object]$CheckRuns, [string[]]$RequiredChecks) {
    foreach ($name in @($RequiredChecks)) {
        # A rerun can coexist with an older successful run. The newest started run is authoritative.
        $matches = @($CheckRuns | Where-Object { $_.name -eq $name } |
            Sort-Object -Property @{ Expression = { [datetimeoffset]::Parse([string]$_.started_at) }; Descending = $true })
        if ($matches.Count -eq 0 -or $matches[0].status -ne "completed") {
            return [pscustomobject]@{ Status = "pending"; Detail = "waiting for $name" }
        }
        if ($matches[0].conclusion -ne "success") {
            return [pscustomobject]@{ Status = "failure"; Detail = "$name is $($matches[0].conclusion)" }
        }
    }
    return [pscustomobject]@{ Status = "success"; Detail = "all required checks passed" }
}

function Assert-String([object]$Value, [string]$Field, [string]$Pattern) {
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -notmatch $Pattern) {
        throw "Invalid project registry field: $Field"
    }
    return $text
}

function Read-ProjectRegistry([string]$ManagerRoot, [string]$ServerRoot) {
    $path = Join-Path $ManagerRoot "projects.json"
    if (-not (Test-Path -LiteralPath $path)) { throw "Project registry is missing: $path" }
    $registry = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($registry.schemaVersion -ne 1) { throw "Unsupported projects.json schemaVersion" }

    $serverFull = [IO.Path]::GetFullPath($ServerRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $seen = @{}
    $result = @()
    foreach ($project in @($registry.projects)) {
        $id = Assert-String $project.id "id" '^[a-z0-9][a-z0-9_-]{0,63}$'
        if ($seen.ContainsKey($id)) { throw "Duplicate project id: $id" }
        $seen[$id] = $true
        if ($project.enabled -ne $true) { continue }
        $null = Assert-String $project.repository "repository" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
        $null = Assert-String $project.remote "remote" '^[A-Za-z0-9_.-]+$'
        $null = Assert-String $project.deployBranch "deployBranch" '^main$'
        $null = Assert-String $project.composeProject "composeProject" '^[a-z0-9][a-z0-9_-]{0,62}$'
        $null = Assert-String $project.composeFile "composeFile" '^[A-Za-z0-9_.-]+\.ya?ml$'
        if (@($project.requiredChecks).Count -eq 0) { throw "$id has no requiredChecks" }
        if (@($project.healthChecks).Count -eq 0) { throw "$id has no healthChecks" }

        $projectPath = [IO.Path]::GetFullPath((Join-Path $serverFull ([string]$project.path)))
        $prefix = $serverFull + [IO.Path]::DirectorySeparatorChar
        if (-not $projectPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$id path must remain below the configured Server root"
        }
        $project | Add-Member -NotePropertyName fullPath -NotePropertyValue $projectPath -Force
        $result += $project
    }
    return @($result)
}

function Invoke-NativeCommand(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory,
    [hashtable]$Environment = @{}
) {
    $previous = @{}
    foreach ($name in $Environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], "Process")
    }
    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $lines }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
        }
    }
}

function Get-GitTarget([object]$Project) {
    if (-not (Test-Path -LiteralPath (Join-Path $Project.fullPath ".git"))) {
        return [pscustomobject]@{ Ready = $false; Reason = "not_git_clone" }
    }
    $status = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "status", "--porcelain") $null
    if ($status.ExitCode -ne 0) {
        return [pscustomobject]@{ Ready = $false; Reason = "git_status_failed" }
    }
    if (@($status.Output).Count -gt 0) {
        return [pscustomobject]@{ Ready = $false; Reason = "dirty_worktree" }
    }
    $branch = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "branch", "--show-current") $null
    $branchName = (@($branch.Output) -join "").Trim()
    if ($branch.ExitCode -ne 0 -or $branchName -ne $Project.deployBranch) {
        return [pscustomobject]@{ Ready = $false; Reason = "wrong_branch"; Branch = $branchName }
    }
    $fetch = Invoke-NativeCommand "git" @(
        "-C", $Project.fullPath, "fetch", "--quiet", $Project.remote,
        "refs/heads/$($Project.deployBranch):refs/remotes/$($Project.remote)/$($Project.deployBranch)"
    ) $null
    if ($fetch.ExitCode -ne 0) {
        return [pscustomobject]@{ Ready = $false; Reason = "git_fetch_failed" }
    }
    $local = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "rev-parse", "HEAD") $null
    $remoteRef = "$($Project.remote)/$($Project.deployBranch)"
    $remote = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "rev-parse", $remoteRef) $null
    $localSha = (@($local.Output) -join "").Trim()
    $remoteSha = (@($remote.Output) -join "").Trim()
    if ($local.ExitCode -ne 0 -or $remote.ExitCode -ne 0 -or
        $localSha -notmatch '^[0-9a-f]{40}$' -or $remoteSha -notmatch '^[0-9a-f]{40}$') {
        return [pscustomobject]@{ Ready = $false; Reason = "invalid_git_revision" }
    }
    $ancestor = Invoke-NativeCommand "git" @(
        "-C", $Project.fullPath, "merge-base", "--is-ancestor", $localSha, $remoteSha
    ) $null
    if ($ancestor.ExitCode -ne 0) {
        return [pscustomobject]@{ Ready = $false; Reason = "non_fast_forward" }
    }
    return [pscustomobject]@{
        Ready = $true
        Reason = "ready"
        Branch = $branchName
        LocalSha = $localSha
        RemoteSha = $remoteSha
    }
}

function Get-GitHubCheckGate([object]$Project, [string]$Sha) {
    $headers = @{
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "windows-server-manager"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    $url = "https://api.github.com/repos/$($Project.repository)/commits/$Sha/check-runs?per_page=100"
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 30
    }
    catch {
        return [pscustomobject]@{ Status = "pending"; Detail = "GitHub checks unavailable" }
    }
    return Get-RequiredCheckGate $response.check_runs @($Project.requiredChecks)
}

function Get-ComposeArguments([object]$Project, [string]$ComposePath, [string]$OverridePath) {
    $arguments = @("compose", "-p", $Project.composeProject, "-f", $ComposePath)
    if ($OverridePath) { $arguments += @("-f", $OverridePath) }
    return $arguments
}

function Get-HealthyOverridePath([string]$ManagerRoot, [object]$Project, [object]$State) {
    if ([string]::IsNullOrWhiteSpace([string]$State.healthySha)) { return $null }
    $path = Join-Path (Join-Path (Join-Path $ManagerRoot "state") "releases") (
        Join-Path $Project.id "$($State.healthySha).compose.override.yaml"
    )
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return $path
}

function Write-ImageOverride(
    [object]$Project,
    [string[]]$Services,
    [string]$Sha,
    [string]$Path
) {
    $lines = @("services:")
    foreach ($service in $Services) {
        if ($service -notmatch '^[A-Za-z0-9_.-]+$') { throw "Unsafe Compose service name" }
        $image = "windows-server-manager/$($Project.id)-$(ConvertTo-SafeName $service):$Sha"
        $lines += "  $service`:"
        $lines += "    image: `"$image`""
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllLines($Path, $lines, (New-Object Text.UTF8Encoding($false)))
}

function Save-RunningImages(
    [object]$Project,
    [string]$ComposePath,
    [string[]]$Services,
    [string]$PreviousSha,
    [string]$PreviousOverride
) {
    Write-ImageOverride $Project $Services $PreviousSha $PreviousOverride
    $base = Get-ComposeArguments $Project $ComposePath $null
    foreach ($service in $Services) {
        $container = Invoke-NativeCommand "docker" ($base + @("ps", "-q", $service)) $Project.fullPath
        $containerId = (@($container.Output) -join "").Trim()
        if ($container.ExitCode -ne 0 -or -not $containerId) { continue }
        $inspect = Invoke-NativeCommand "docker" @("inspect", "--format", "{{.Image}}", $containerId) $null
        $imageId = (@($inspect.Output) -join "").Trim()
        if ($inspect.ExitCode -ne 0 -or -not $imageId) { continue }
        $tag = "windows-server-manager/$($Project.id)-$(ConvertTo-SafeName $service):$PreviousSha"
        $tagged = Invoke-NativeCommand "docker" @("tag", $imageId, $tag) $null
        if ($tagged.ExitCode -ne 0) { throw "Could not preserve running image for $service" }
    }
}

function Test-HealthVersion([object]$Check, [string]$Sha) {
    try {
        $response = Invoke-RestMethod -Uri $Check.url -Method Get -TimeoutSec 5
    }
    catch { return $false }
    if (-not [string]::IsNullOrWhiteSpace([string]$Check.versionField)) {
        $property = $response.PSObject.Properties[[string]$Check.versionField]
        if ($null -eq $property) { return $false }
        $actual = [string]$property.Value
        if ($actual -ne $Sha -and $actual -ne $Sha.Substring(0, 12)) { return $false }
    }
    return $true
}

function Wait-ProjectHealth([object]$Project, [string]$Sha) {
    $deadline = (Get-UtcNow).AddSeconds([int]$Project.healthTimeoutSeconds)
    $consecutive = 0
    while ((Get-UtcNow) -lt $deadline) {
        $allHealthy = $true
        foreach ($check in @($Project.healthChecks)) {
            if (-not (Test-HealthVersion $check $Sha)) { $allHealthy = $false; break }
        }
        if ($allHealthy) {
            $consecutive++
            if ($consecutive -ge [int]$Project.healthSuccessesRequired) { return $true }
        }
        else { $consecutive = 0 }
        Start-Sleep -Seconds ([int]$Project.healthIntervalSeconds)
    }
    return $false
}

function Invoke-MigrationHook(
    [object]$Project,
    [string]$ComposePath,
    [string]$OverridePath,
    [string]$Sha
) {
    if ($null -eq $Project.migrationHook) { return }
    if ($Project.migrationHook.rollbackSafe -ne $true) {
        throw "Migration hook is disabled until rollbackSafe is explicitly true"
    }
    $service = Assert-String $Project.migrationHook.service "migrationHook.service" '^[A-Za-z0-9_.-]+$'
    $command = @($Project.migrationHook.command | ForEach-Object { [string]$_ })
    if ($command.Count -eq 0) { throw "migrationHook.command is empty" }
    $base = Get-ComposeArguments $Project $ComposePath $OverridePath
    $result = Invoke-NativeCommand "docker" (
        $base + @("run", "--rm", "--no-deps", $service) + $command
    ) $Project.fullPath @{ APP_VERSION = $Sha }
    if ($result.ExitCode -ne 0) { throw "Migration hook failed: $($result.Output -join ' ')" }
}

function Invoke-RealReleaseDeployment(
    [object]$Project,
    [string]$ManagerRoot,
    [string]$DesiredSha,
    [string]$PreviousSha
) {
    $stateReleaseRoot = Join-Path (Join-Path $ManagerRoot "state") "releases"
    $projectStateRoot = Join-Path $stateReleaseRoot $Project.id
    $stageRoot = Join-Path (Split-Path -Parent $ManagerRoot) ".windows-server-manager-releases"
    $stage = Join-Path (Join-Path $stageRoot $Project.id) $DesiredSha
    $candidateOverride = Join-Path $projectStateRoot "$DesiredSha.compose.override.yaml"
    $rollbackTag = "rollback-$DesiredSha"
    $previousOverride = Join-Path $projectStateRoot "$DesiredSha.rollback.compose.override.yaml"
    $liveCompose = Join-Path $Project.fullPath $Project.composeFile
    $switched = $false
    try {
        if (Test-Path -LiteralPath $stage) {
            $null = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "worktree", "remove", "--force", $stage) $null
            Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Force -Path $projectStateRoot | Out-Null
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stage) | Out-Null
        $worktree = Invoke-NativeCommand "git" @(
            "-C", $Project.fullPath, "worktree", "add", "--detach", "--force", $stage, $DesiredSha
        ) $null
        if ($worktree.ExitCode -ne 0) { throw "Could not create isolated release worktree" }
        foreach ($runtimeFile in @($Project.runtimeFiles)) {
            $name = [string]$runtimeFile
            if ($name -notmatch '^[A-Za-z0-9_.-]+$') { throw "Unsafe runtime file name" }
            $source = Join-Path $Project.fullPath $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) }
        }
        $stageCompose = Join-Path $stage $Project.composeFile
        if (-not (Test-Path -LiteralPath $stageCompose)) { throw "Compose file is missing at desired SHA" }
        $candidateServiceResult = Invoke-NativeCommand "docker" (
            (Get-ComposeArguments $Project $stageCompose $null) + @("config", "--services")
        ) $stage @{ APP_VERSION = $DesiredSha }
        if ($candidateServiceResult.ExitCode -ne 0) { throw "Candidate Compose configuration is invalid" }
        $candidateServices = @($candidateServiceResult.Output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
        if ($candidateServices.Count -eq 0) { throw "Candidate Compose project has no services" }
        $previousServiceResult = Invoke-NativeCommand "docker" (
            (Get-ComposeArguments $Project $liveCompose $null) + @("config", "--services")
        ) $Project.fullPath @{ APP_VERSION = $PreviousSha }
        if ($previousServiceResult.ExitCode -ne 0) { throw "Current Compose configuration is invalid" }
        $previousServices = @($previousServiceResult.Output | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
        if ($previousServices.Count -eq 0) { throw "Current Compose project has no services" }
        Write-ImageOverride $Project $candidateServices $DesiredSha $candidateOverride
        # The previous and candidate service sets may differ (for example a web/worker split).
        # Preserve only services that actually exist in the previous Compose file so rollback
        # cannot invent an incomplete new service while running old code.
        Save-RunningImages $Project $liveCompose $previousServices $rollbackTag $previousOverride

        $build = Invoke-NativeCommand "docker" (
            (Get-ComposeArguments $Project $stageCompose $candidateOverride) + @("build")
        ) $stage @{ APP_VERSION = $DesiredSha }
        if ($build.ExitCode -ne 0) { throw "Candidate image build failed: $($build.Output -join ' ')" }

        $checkout = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "reset", "--hard", $DesiredSha) $null
        if ($checkout.ExitCode -ne 0) { throw "Could not move the deployment checkout to desired SHA" }
        $switched = $true
        $liveCompose = Join-Path $Project.fullPath $Project.composeFile
        Invoke-MigrationHook $Project $liveCompose $candidateOverride $DesiredSha
        $up = Invoke-NativeCommand "docker" (
            (Get-ComposeArguments $Project $liveCompose $candidateOverride) +
            @("up", "-d", "--no-build", "--remove-orphans")
        ) $Project.fullPath @{ APP_VERSION = $DesiredSha }
        if ($up.ExitCode -ne 0) { throw "Candidate container start failed: $($up.Output -join ' ')" }
        if (-not (Wait-ProjectHealth $Project $DesiredSha)) {
            throw "Candidate did not pass consecutive health checks"
        }
        return [pscustomobject]@{ Success = $true; Error = $null; RolledBack = $false }
    }
    catch {
        $failure = $_.Exception.Message
        if ($switched) {
            $reset = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "reset", "--hard", $PreviousSha) $null
            $rollbackCompose = Join-Path $Project.fullPath $Project.composeFile
            $rollback = Invoke-NativeCommand "docker" (
                (Get-ComposeArguments $Project $rollbackCompose $previousOverride) +
                @("up", "-d", "--no-build", "--remove-orphans")
            ) $Project.fullPath @{ APP_VERSION = $PreviousSha }
            if ($reset.ExitCode -ne 0 -or $rollback.ExitCode -ne 0 -or
                -not (Wait-ProjectHealth $Project $PreviousSha)) {
                return [pscustomobject]@{
                    Success = $false
                    Error = "$failure; automatic rollback also failed"
                    RolledBack = $false
                    RecoveryRequired = $true
                }
            }
            return [pscustomobject]@{ Success = $false; Error = $failure; RolledBack = $true }
        }
        return [pscustomobject]@{ Success = $false; Error = $failure; RolledBack = $false }
    }
    finally {
        if (Test-Path -LiteralPath $stage) {
            $null = Invoke-NativeCommand "git" @("-C", $Project.fullPath, "worktree", "remove", "--force", $stage) $null
            Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue
        }
    }
}

function Enter-ProjectMutex([string]$ProjectId) {
    $safe = ConvertTo-SafeName $ProjectId
    $prefix = if ($env:OS -eq "Windows_NT") { "Global\" } else { "" }
    $mutex = New-Object System.Threading.Mutex($false, "$prefix`WindowsServerManager-$safe")
    try {
        $acquired = $mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { $mutex.Dispose(); return $null }
    return $mutex
}

function Exit-ProjectMutex([object]$Mutex) {
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Get-HookResult([hashtable]$Hooks, [string]$Name, [object[]]$Arguments, [scriptblock]$Default) {
    if ($null -ne $Hooks -and $Hooks.ContainsKey($Name)) {
        return & $Hooks[$Name] @Arguments
    }
    return & $Default
}

function Invoke-ProjectCycle(
    [object]$Project,
    [string]$ManagerRoot,
    [switch]$ForceRetry,
    [hashtable]$Hooks = $null
) {
    $mutex = Enter-ProjectMutex $Project.id
    if ($null -eq $mutex) {
        return [pscustomobject]@{ Status = "locked"; State = (Read-DeploymentState $ManagerRoot $Project.id) }
    }
    try {
        $now = Get-HookResult $Hooks "Now" @() { Get-UtcNow }
        $state = Read-DeploymentState $ManagerRoot $Project.id
        if ($state.status -eq "recovery_required") {
            return [pscustomobject]@{ Status = "recovery_required"; State = $state }
        }
        $target = Get-HookResult $Hooks "Target" @($Project) { Get-GitTarget $Project }
        if (-not $target.Ready) {
            $state.status = "blocked_$($target.Reason)"
            $state.lastError = $target.Reason
            Write-DeploymentState $ManagerRoot $state
            Write-ManagerLog $ManagerRoot $Project.id "blocked" $target.Reason
            return [pscustomobject]@{ Status = $state.status; State = $state }
        }
        $desired = [string]$target.RemoteSha
        if ($state.healthySha -and $state.healthySha -ne $target.LocalSha) {
            $state.status = "blocked_checkout_drift"
            $state.lastError = "local checkout differs from recorded healthy SHA"
            Write-DeploymentState $ManagerRoot $state
            return [pscustomobject]@{ Status = $state.status; State = $state }
        }
        if ($state.desiredSha -ne $desired) {
            $state.desiredSha = $desired
            $state.failureCount = 0
            $state.nextRetryAt = $null
            $state.lastError = $null
        }
        if ($state.healthySha -eq $desired) {
            $state.status = "healthy"
            $state.lastError = $null
            Write-DeploymentState $ManagerRoot $state
            return [pscustomobject]@{ Status = "healthy"; State = $state }
        }
        if (-not $ForceRetry -and $state.status -eq "paused") {
            return [pscustomobject]@{ Status = "paused"; State = $state }
        }
        if (-not $ForceRetry -and $state.nextRetryAt) {
            if ($state.nextRetryAt -is [datetime]) {
                $retryAt = $state.nextRetryAt.ToUniversalTime()
            }
            else {
                $retryAt = [datetimeoffset]::Parse(
                    [string]$state.nextRetryAt,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                ).UtcDateTime
            }
            if ($now -lt $retryAt) {
                return [pscustomobject]@{ Status = "backoff"; State = $state }
            }
        }
        $gate = Get-HookResult $Hooks "Checks" @($Project, $desired) {
            Get-GitHubCheckGate $Project $desired
        }
        if ($gate.Status -ne "success") {
            $state.status = if ($gate.Status -eq "failure") { "blocked_ci" } else { "waiting_ci" }
            $state.lastError = $gate.Detail
            Write-DeploymentState $ManagerRoot $state
            return [pscustomobject]@{ Status = $state.status; State = $state }
        }

        $state.status = "deploying"
        $state.lastAttemptAt = $now.ToString('o')
        Write-DeploymentState $ManagerRoot $state
        $deployment = Get-HookResult $Hooks "Deploy" @(
            $Project, $ManagerRoot, $desired, [string]$target.LocalSha
        ) { Invoke-RealReleaseDeployment $Project $ManagerRoot $desired ([string]$target.LocalSha) }
        if ($deployment.Success) {
            $state.previousHealthySha = if ($state.healthySha) {
                $state.healthySha
            }
            else { [string]$target.LocalSha }
            $state.deployedSha = $desired
            $state.healthySha = $desired
            $state.status = "healthy"
            $state.failureCount = 0
            $state.nextRetryAt = $null
            $state.lastHealthyAt = $now.ToString('o')
            $state.lastError = $null
            Write-DeploymentState $ManagerRoot $state
            Write-ManagerLog $ManagerRoot $Project.id "healthy" "sha=$desired"
            return [pscustomobject]@{ Status = "healthy"; State = $state }
        }

        $state.failureCount = [int]$state.failureCount + 1
        $state.lastError = ConvertTo-SafeMessage ([string]$deployment.Error)
        $recoveryRequired = (
            $null -ne $deployment.PSObject.Properties['RecoveryRequired'] -and
            $deployment.RecoveryRequired -eq $true
        )
        if ($recoveryRequired) {
            $state.status = "recovery_required"
            $state.nextRetryAt = $null
        }
        elseif ($state.failureCount -ge 3) {
            $state.status = "paused"
            $state.nextRetryAt = $null
        }
        else {
            $delays = @($Project.retryMinutes)
            $index = [Math]::Min($state.failureCount - 1, $delays.Count - 1)
            $state.status = "failed"
            $state.nextRetryAt = $now.AddMinutes([int]$delays[$index]).ToString('o')
        }
        Write-DeploymentState $ManagerRoot $state
        Write-ManagerLog $ManagerRoot $Project.id "deploy_failed" (
            "sha=$desired failures=$($state.failureCount) status=$($state.status) error=$($state.lastError)"
        )
        return [pscustomobject]@{ Status = $state.status; State = $state }
    }
    finally { Exit-ProjectMutex $mutex }
}

Export-ModuleMember -Function @(
    'Get-StatePath', 'New-DeploymentState', 'Read-DeploymentState', 'Write-DeploymentState',
    'Write-ManagerLog', 'Read-ProjectRegistry', 'Invoke-NativeCommand', 'Get-GitTarget',
    'Get-RequiredCheckGate', 'Get-GitHubCheckGate', 'Get-ComposeArguments',
    'Get-HealthyOverridePath', 'Write-ImageOverride',
    'Test-HealthVersion', 'Wait-ProjectHealth', 'Invoke-RealReleaseDeployment',
    'Enter-ProjectMutex', 'Exit-ProjectMutex', 'Invoke-ProjectCycle'
)

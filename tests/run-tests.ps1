$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Import-Module (Join-Path $Root "lib/DeploymentManager.psm1") -Force
$script:Passed = 0

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Message) {
    if ([string]$Actual -ne [string]$Expected) {
        throw "$Message (expected=$Expected actual=$Actual)"
    }
}

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}

function Invoke-Test([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:Passed++
    Write-Host "PASS $Name"
}

function New-TestProject {
    return [pscustomobject]@{
        id = "fixture"
        retryMinutes = @(5, 15, 30)
    }
}

function New-TestRoot {
    $path = Join-Path ([IO.Path]::GetTempPath()) "wsm-test-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

$oldSha = "1111111111111111111111111111111111111111"
$newSha = "2222222222222222222222222222222222222222"

Invoke-Test "registry is explicit and restricted to main" {
    $projects = @(Read-ProjectRegistry $Root (Split-Path -Parent $Root))
    Assert-Equal $projects.Count 1 "one project should be registered"
    Assert-Equal $projects[0].id "infohub" "InfoHub should be explicit"
    Assert-Equal $projects[0].deployBranch "main" "only main should deploy"
    Assert-Equal $projects[0].requiredChecks.Count 3 "required checks should be explicit"
}

Invoke-Test "a newer in-progress check rerun blocks an older success" {
    $runs = @(
        [pscustomobject]@{
            name = "docker"; status = "completed"; conclusion = "success"
            started_at = "2026-09-15T12:00:00Z"
        },
        [pscustomobject]@{
            name = "docker"; status = "in_progress"; conclusion = $null
            started_at = "2026-09-15T12:05:00Z"
        }
    )
    $gate = Get-RequiredCheckGate $runs @("docker")
    Assert-Equal $gate.Status "pending" "newer rerun should be authoritative"
}

Invoke-Test "manager logs redact common secrets and cap untrusted output" {
    $testRoot = New-TestRoot
    try {
        Write-ManagerLog $testRoot "fixture" "failure" (
            "token=secret-value password:other Authorization: Bearer third-secret " + ("x" * 3000)
        )
        $line = Get-Content -LiteralPath (Join-Path $testRoot "logs/auto-deploy.log") -Raw
        Assert-True (-not $line.Contains("secret-value")) "token value should not be logged"
        Assert-True (-not $line.Contains("other")) "password value should not be logged"
        Assert-True (-not $line.Contains("third-secret")) "authorization value should not be logged"
        Assert-True ($line.Contains("[truncated]")) "long output should be truncated"
        Assert-True ($line.Length -lt 2300) "log line should remain bounded"
    }
    finally { Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue }
}

Invoke-Test "candidate and first-release rollback image tags stay distinct" {
    $testRoot = New-TestRoot
    try {
        $project = [pscustomobject]@{ id = "fixture" }
        $candidate = Join-Path $testRoot "candidate.yaml"
        $rollback = Join-Path $testRoot "rollback.yaml"
        Write-ImageOverride $project @("web") $newSha $candidate
        Write-ImageOverride $project @("web") "rollback-$newSha" $rollback
        $candidateText = Get-Content -LiteralPath $candidate -Raw
        $rollbackText = Get-Content -LiteralPath $rollback -Raw
        Assert-True ($candidateText -ne $rollbackText) "rollback image must not share candidate tag"
        Assert-True ($rollbackText.Contains("rollback-$newSha")) "rollback tag should be explicit"
    }
    finally { Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue }
}

Invoke-Test "rollback override contains only services from the previous release" {
    $testRoot = New-TestRoot
    try {
        $project = [pscustomobject]@{ id = "fixture" }
        $candidate = Join-Path $testRoot "candidate.yaml"
        $rollback = Join-Path $testRoot "rollback.yaml"
        Write-ImageOverride $project @("infohub", "worker") $newSha $candidate
        Write-ImageOverride $project @("infohub") "rollback-$newSha" $rollback
        $candidateText = Get-Content -LiteralPath $candidate -Raw
        $rollbackText = Get-Content -LiteralPath $rollback -Raw
        Assert-True ($candidateText.Contains("worker:")) "candidate should include new worker"
        Assert-True (-not $rollbackText.Contains("worker:")) "old rollback must not invent worker"
    }
    finally { Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue }
}

Invoke-Test "failed SHA is retried and can become healthy without a new commit" {
    $testRoot = New-TestRoot
    try {
        $project = New-TestProject
        $script:attempts = 0
        $script:now = [datetime]::Parse("2026-09-15T12:00:00Z").ToUniversalTime()
        $hooks = @{
            Now = { $script:now }
            Target = { param($ignored) [pscustomobject]@{
                Ready = $true; LocalSha = $oldSha; RemoteSha = $newSha
            } }
            Checks = { param($ignoredProject, $ignoredSha) [pscustomobject]@{
                Status = "success"; Detail = "ok"
            } }
            Deploy = {
                param($ignoredProject, $ignoredRoot, $ignoredDesired, $ignoredPrevious)
                $script:attempts++
                if ($script:attempts -eq 1) {
                    return [pscustomobject]@{ Success = $false; Error = "injected build failure token=secret" }
                }
                return [pscustomobject]@{ Success = $true; Error = $null }
            }
        }
        $first = Invoke-ProjectCycle $project $testRoot -Hooks $hooks
        Assert-Equal $first.Status "failed" "first build should fail"
        Assert-Equal $first.State.failureCount 1 "failure count should persist"
        Assert-Equal $first.State.desiredSha $newSha "desired SHA should persist"
        Assert-True ($null -ne $first.State.nextRetryAt) "retry time should be recorded"
        Assert-True (-not $first.State.lastError.Contains("secret")) "state must redact command secrets"

        $early = Invoke-ProjectCycle $project $testRoot -Hooks $hooks
        Assert-Equal $early.Status "backoff" "automatic retry should respect backoff"
        Assert-Equal $script:attempts 1 "backoff must not run another build"

        $script:now = $script:now.AddMinutes(6)
        $second = Invoke-ProjectCycle $project $testRoot -Hooks $hooks
        Assert-Equal $second.Status "healthy" "same SHA should succeed on retry"
        Assert-Equal $script:attempts 2 "same SHA should be attempted twice"
        Assert-Equal $second.State.healthySha $newSha "healthy SHA should be exact"
        Assert-Equal $second.State.previousHealthySha $oldSha "previous SHA should be retained"
        Assert-Equal $second.State.failureCount 0 "successful retry should clear failures"
    }
    finally { Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue }
}

Invoke-Test "dirty checkout, wrong branch and failed CI never invoke deployment" {
    foreach ($case in @("dirty", "branch", "ci")) {
        $testRoot = New-TestRoot
        try {
            $project = New-TestProject
            $script:attempts = 0
            if ($case -in @("dirty", "branch")) {
                $reason = if ($case -eq "dirty") { "dirty_worktree" } else { "wrong_branch" }
                $targetHook = { param($ignored) [pscustomobject]@{
                    Ready = $false; Reason = $reason
                } }.GetNewClosure()
                $checkHook = { throw "checks must not run" }
            }
            else {
                $targetHook = { param($ignored) [pscustomobject]@{
                    Ready = $true; LocalSha = $oldSha; RemoteSha = $newSha
                } }
                $checkHook = { param($a, $b) [pscustomobject]@{
                    Status = "failure"; Detail = "docker is failure"
                } }
            }
            $hooks = @{
                Now = { [datetime]::Parse("2026-09-15T12:00:00Z").ToUniversalTime() }
                Target = $targetHook
                Checks = $checkHook
                Deploy = { $script:attempts++; [pscustomobject]@{ Success = $true } }
            }
            $result = Invoke-ProjectCycle $project $testRoot -Hooks $hooks
            $expected = switch ($case) {
                "dirty" { "blocked_dirty_worktree" }
                "branch" { "blocked_wrong_branch" }
                default { "blocked_ci" }
            }
            Assert-Equal $result.Status $expected "$case should block"
            Assert-Equal $script:attempts 0 "$case must not deploy"
        }
        finally { Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue }
    }
}

Invoke-Test "three deployment failures pause automatic retries" {
    $testRoot = New-TestRoot
    try {
        $project = New-TestProject
        $script:attempts = 0
        $script:now = [datetime]::Parse("2026-09-15T12:00:00Z").ToUniversalTime()
        $hooks = @{
            Now = { $script:now }
            Target = { param($ignored) [pscustomobject]@{
                Ready = $true; LocalSha = $oldSha; RemoteSha = $newSha
            } }
            Checks = { param($a, $b) [pscustomobject]@{ Status = "success"; Detail = "ok" } }
            Deploy = {
                param($a, $b, $c, $d)
                $script:attempts++
                [pscustomobject]@{ Success = $false; Error = "failure $script:attempts" }
            }
        }
        $one = Invoke-ProjectCycle $project $testRoot -ForceRetry -Hooks $hooks
        $two = Invoke-ProjectCycle $project $testRoot -ForceRetry -Hooks $hooks
        $three = Invoke-ProjectCycle $project $testRoot -ForceRetry -Hooks $hooks
        Assert-Equal $one.Status "failed" "first failure should retry"
        Assert-Equal $two.Status "failed" "second failure should retry"
        Assert-Equal $three.Status "paused" "third failure should pause"
        $automatic = Invoke-ProjectCycle $project $testRoot -Hooks $hooks
        Assert-Equal $automatic.Status "paused" "automatic cycle should remain paused"
        Assert-Equal $script:attempts 3 "paused cycle must not deploy"
    }
    finally { Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue }
}

Invoke-Test "project mutex excludes a second process" {
    $mutex = Enter-ProjectMutex "mutex-fixture"
    Assert-True ($null -ne $mutex) "first process should acquire mutex"
    $output = Join-Path ([IO.Path]::GetTempPath()) "wsm-mutex-$([Guid]::NewGuid().ToString('N')).txt"
    try {
        $executable = (Get-Process -Id $PID).Path
        $module = Join-Path $Root "lib/DeploymentManager.psm1"
        $command = @"
Import-Module '$module' -Force
`$m = Enter-ProjectMutex 'mutex-fixture'
if (`$null -eq `$m) { Set-Content -LiteralPath '$output' -Value 'blocked'; exit 0 }
Exit-ProjectMutex `$m
Set-Content -LiteralPath '$output' -Value 'acquired'
exit 1
"@
        $process = Start-Process -FilePath $executable -ArgumentList @(
            "-NoLogo", "-NoProfile", "-Command", $command
        ) -PassThru -Wait
        Assert-Equal $process.ExitCode 0 "second process should be rejected"
        Assert-Equal (Get-Content -LiteralPath $output -Raw).Trim() "blocked" "lock result"
    }
    finally {
        Exit-ProjectMutex $mutex
        Remove-Item -Force -LiteralPath $output -ErrorAction SilentlyContinue
    }
}

Write-Host "All $script:Passed deployment manager tests passed."

param(
    [ValidateSet('baseline','exercise','verify')]
    [string]$Action = 'exercise'
)

$ErrorActionPreference = 'Stop'
$DbContainer = 'nightwatch-db'
$DbUser = 'nightwatch'
$DbName = 'nightwatch'
$TargetId = 84
$BlockerApp = 'opsforge-inc019-blocker'
$WaiterApp = 'opsforge-inc019-waiter'
$EvidenceDir = Join-Path $PSScriptRoot '..\.opsforge\evidence\inc-019'
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

function Invoke-Psql([string]$Sql) {
    docker exec $DbContainer psql -U $DbUser -d $DbName -X -v ON_ERROR_STOP=1 -Atc $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $Sql" }
}

function Clear-IncidentSessions {
    $sql = "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name IN ('$BlockerApp','$WaiterApp') AND pid <> pg_backend_pid();"
    docker exec $DbContainer psql -U $DbUser -d $DbName -X -Atc $sql 2>$null | Out-Null
}

function Stop-JobSafe($Job) {
    if ($null -ne $Job) {
        Stop-Job -Job $Job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Baseline {
    Clear-IncidentSessions
    $count = Invoke-Psql "SELECT count(*) FROM customer_activity WHERE id=$TargetId;"
    if ($count.Trim() -ne '1') { throw "Target row $TargetId missing" }

    docker exec $DbContainer psql -U $DbUser -d $DbName -X -v ON_ERROR_STOP=1 -c "SET lock_timeout='2s'; UPDATE customer_activity SET payload=payload WHERE id=$TargetId;" | Tee-Object -FilePath (Join-Path $EvidenceDir 'baseline-update.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Baseline row update failed' }

    $blocked = Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND cardinality(pg_blocking_pids(pid))>0;"
    $blocked | Set-Content (Join-Path $EvidenceDir 'baseline-blocked-count.txt')
    if ($blocked.Trim() -ne '0') { throw "Baseline already has blocked sessions: $blocked" }
    Write-Host 'INC-019 baseline healthy: target row writable and no blocked sessions.'
}

function Exercise {
    Baseline

    $blockerSql = "SET application_name='$BlockerApp'; BEGIN; UPDATE customer_activity SET payload=payload WHERE id=$TargetId; SELECT pg_sleep(60); ROLLBACK;"
    $waiterSql = "SET application_name='$WaiterApp'; SET lock_timeout='30s'; UPDATE customer_activity SET payload=payload WHERE id=$TargetId;"

    $blockerOut = Join-Path $EvidenceDir 'blocker.out.txt'
    $blockerErr = Join-Path $EvidenceDir 'blocker.err.txt'
    $waiterOut = Join-Path $EvidenceDir 'waiter.out.txt'
    $waiterErr = Join-Path $EvidenceDir 'waiter.err.txt'

    $blocker = $null
    $waiter = $null

    try {
        $blocker = Start-Job -ArgumentList $DbContainer,$DbUser,$DbName,$blockerSql,$blockerOut,$blockerErr -ScriptBlock {
            param($Container,$User,$Database,$Sql,$OutFile,$ErrFile)
            & docker exec $Container psql -U $User -d $Database -X -v ON_ERROR_STOP=1 -c $Sql 1> $OutFile 2> $ErrFile
            if ($LASTEXITCODE -ne 0) { throw "blocker psql exited $LASTEXITCODE" }
        }

        $blockerReady = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            $count = Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE application_name='$BlockerApp' AND xact_start IS NOT NULL;"
            if ($count.Trim() -eq '1') { $blockerReady = $true; break }
        }
        if (-not $blockerReady) { throw 'Blocker transaction did not become active' }

        $waiter = Start-Job -ArgumentList $DbContainer,$DbUser,$DbName,$waiterSql,$waiterOut,$waiterErr -ScriptBlock {
            param($Container,$User,$Database,$Sql,$OutFile,$ErrFile)
            & docker exec $Container psql -U $User -d $Database -X -v ON_ERROR_STOP=1 -c $Sql 1> $OutFile 2> $ErrFile
            if ($LASTEXITCODE -ne 0) { throw "waiter psql exited $LASTEXITCODE" }
        }

        $pairCount = '0'
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 250
            $pairCount = Invoke-Psql "SELECT count(*) FROM pg_stat_activity w WHERE w.application_name='$WaiterApp' AND w.wait_event_type='Lock' AND cardinality(pg_blocking_pids(w.pid))>0;"
            if ($pairCount.Trim() -eq '1') { break }
        }

        $diag = @"
SELECT w.pid AS blocked_pid,
       w.application_name AS blocked_app,
       w.state AS blocked_state,
       w.wait_event_type,
       w.wait_event,
       b.pid AS blocker_pid,
       b.application_name AS blocker_app,
       b.state AS blocker_state,
       age(clock_timestamp(), b.xact_start) AS blocker_xact_age,
       left(w.query,100) AS blocked_query,
       left(b.query,100) AS blocker_query
FROM pg_stat_activity w
CROSS JOIN LATERAL unnest(pg_blocking_pids(w.pid)) AS p(blocker_pid)
JOIN pg_stat_activity b ON b.pid=p.blocker_pid
WHERE w.application_name='$WaiterApp';
"@

        docker exec $DbContainer psql -U $DbUser -d $DbName -X -P pager=off -c $diag | Tee-Object -FilePath (Join-Path $EvidenceDir 'blocking-diagnostics.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Blocking diagnostics failed' }

        $pairCount | Set-Content (Join-Path $EvidenceDir 'blocked-session-count.txt')
        if ($pairCount.Trim() -ne '1') {
            throw "Expected one blocked waiter, observed $pairCount"
        }

        $blockerPid = Invoke-Psql "SELECT pid FROM pg_stat_activity WHERE application_name='$BlockerApp' AND xact_start IS NOT NULL;"
        if (-not $blockerPid.Trim()) { throw 'Could not identify blocker PID' }
        "blocker_pid=$($blockerPid.Trim())`napplication_name=$BlockerApp" | Set-Content (Join-Path $EvidenceDir 'recovery-target.txt')

        $terminated = Invoke-Psql "SELECT pg_terminate_backend($($blockerPid.Trim()));"
        $terminated | Set-Content (Join-Path $EvidenceDir 'recovery-action.txt')
        if ($terminated.Trim() -ne 't') { throw 'Targeted blocker termination failed' }

        $completed = Wait-Job -Job $waiter -Timeout 10
        if ($null -eq $completed) { throw 'Blocked waiter did not complete after blocker termination' }
        Receive-Job -Job $waiter -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1

        $remaining = Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('$BlockerApp','$WaiterApp');"
        $remaining | Set-Content (Join-Path $EvidenceDir 'post-recovery-session-count.txt')
        if ($remaining.Trim() -ne '0') { throw "Incident sessions remained after recovery: $remaining" }

        docker exec $DbContainer psql -U $DbUser -d $DbName -X -v ON_ERROR_STOP=1 -c "SET lock_timeout='2s'; UPDATE customer_activity SET payload=payload WHERE id=$TargetId;" | Tee-Object -FilePath (Join-Path $EvidenceDir 'post-recovery-update.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Post-recovery update failed' }

        $health = Invoke-Psql 'SELECT 1;'
        $health | Set-Content (Join-Path $EvidenceDir 'post-recovery-db-health.txt')

        Write-Host 'INC-019 exercise verified: live row-lock contention captured, blocker identified with pg_blocking_pids(), targeted backend terminated, waiter released, and write path recovered.'
    }
    finally {
        Clear-IncidentSessions
        Stop-JobSafe $waiter
        Stop-JobSafe $blocker
    }
}

function Verify {
    Clear-IncidentSessions
    $remaining = Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('$BlockerApp','$WaiterApp');"
    if ($remaining.Trim() -ne '0') { throw "INC-019 sessions still present: $remaining" }
    docker exec $DbContainer psql -U $DbUser -d $DbName -X -v ON_ERROR_STOP=1 -c "SET lock_timeout='2s'; UPDATE customer_activity SET payload=payload WHERE id=$TargetId;"
    if ($LASTEXITCODE -ne 0) { throw 'Verification write failed' }
    Write-Host 'INC-019 verification passed.'
}

switch ($Action) {
    'baseline' { Baseline }
    'exercise' { Exercise }
    'verify'   { Verify }
}

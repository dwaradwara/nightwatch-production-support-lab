param(
    [ValidateSet('baseline','exercise','verify')]
    [string]$Action = 'exercise'
)

$ErrorActionPreference = 'Stop'
$RedisContainer = 'nightwatch-redis'
$ApiBase = 'http://localhost:8000'
$EvidenceDir = Join-Path $PSScriptRoot '..\.opsforge\evidence\inc-020'
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

function Get-HttpResult([string]$Path) {
    try {
        $r = Invoke-WebRequest -Uri "$ApiBase$Path" -Method GET -TimeoutSec 10
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $r.Content }
    }
    catch {
        $status = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        $body = $_.ErrorDetails.Message
        return [pscustomobject]@{ Status = $status; Body = $body }
    }
}

function Assert-Status($Result, [int]$Expected, [string]$Label) {
    if ($Result.Status -ne $Expected) {
        throw "$Label expected HTTP $Expected but got $($Result.Status). Body: $($Result.Body)"
    }
}

function Baseline {
    docker start $RedisContainer 2>$null | Out-Null
    Start-Sleep -Seconds 3

    $ready = Get-HttpResult '/health/ready'
    $cache = Get-HttpResult '/cache-health'
    $tickets = Get-HttpResult '/api/tickets'

    Assert-Status $ready 200 'Baseline readiness'
    Assert-Status $cache 200 'Baseline cache health'
    Assert-Status $tickets 200 'Baseline ticket path'

    $ready.Body | Set-Content (Join-Path $EvidenceDir 'baseline-readiness.json')
    $cache.Body | Set-Content (Join-Path $EvidenceDir 'baseline-cache-health.json')
    $tickets.Body | Set-Content (Join-Path $EvidenceDir 'baseline-tickets.json')
    Write-Host 'INC-020 baseline healthy: readiness, Redis health, and ticket read path all return HTTP 200.'
}

function Exercise {
    Baseline

    docker stop $RedisContainer | Tee-Object -FilePath (Join-Path $EvidenceDir 'redis-stop.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Failed to stop Redis container' }
    Start-Sleep -Seconds 2

    $cache = Get-HttpResult '/cache-health'
    $ready = Get-HttpResult '/health/ready'
    $tickets = Get-HttpResult '/api/tickets'

    $cache.Body | Set-Content (Join-Path $EvidenceDir 'incident-cache-health.json')
    $ready.Body | Set-Content (Join-Path $EvidenceDir 'incident-readiness.json')
    $tickets.Body | Set-Content (Join-Path $EvidenceDir 'incident-tickets.json')
    "cache_http=$($cache.Status)`nreadiness_http=$($ready.Status)`ntickets_http=$($tickets.Status)" | Set-Content (Join-Path $EvidenceDir 'incident-http-status.txt')

    Assert-Status $cache 503 'Redis health after outage'
    Assert-Status $ready 503 'Readiness after Redis outage'
    Assert-Status $tickets 200 'Ticket read path during Redis outage'

    $healthState = docker inspect nightwatch-api --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}'
    $healthState | Set-Content (Join-Path $EvidenceDir 'api-container-health.txt')

    Write-Host 'INC-020 incident proven: Redis is unavailable and readiness is HTTP 503, while the PostgreSQL-backed ticket read path remains HTTP 200.'

    docker start $RedisContainer | Tee-Object -FilePath (Join-Path $EvidenceDir 'redis-start.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Failed to restart Redis container' }

    $recovered = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $readyAfter = Get-HttpResult '/health/ready'
        if ($readyAfter.Status -eq 200) {
            $recovered = $true
            $readyAfter.Body | Set-Content (Join-Path $EvidenceDir 'post-recovery-readiness.json')
            break
        }
    }
    if (-not $recovered) { throw 'Readiness did not recover after Redis restart' }

    $cacheAfter = Get-HttpResult '/cache-health'
    $ticketsAfter = Get-HttpResult '/api/tickets'
    Assert-Status $cacheAfter 200 'Post-recovery cache health'
    Assert-Status $ticketsAfter 200 'Post-recovery ticket path'
    $cacheAfter.Body | Set-Content (Join-Path $EvidenceDir 'post-recovery-cache-health.json')
    $ticketsAfter.Body | Set-Content (Join-Path $EvidenceDir 'post-recovery-tickets.json')

    Write-Host 'INC-020 exercise verified: Redis outage made readiness fail without breaking the core ticket read path; Redis restore returned full readiness.'
}

function Verify {
    docker start $RedisContainer 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $ready = Get-HttpResult '/health/ready'
    $cache = Get-HttpResult '/cache-health'
    $tickets = Get-HttpResult '/api/tickets'
    Assert-Status $ready 200 'Verification readiness'
    Assert-Status $cache 200 'Verification cache health'
    Assert-Status $tickets 200 'Verification ticket path'
    Write-Host 'INC-020 verification passed.'
}

switch ($Action) {
    'baseline' { Baseline }
    'exercise' { try { Exercise } finally { docker start $RedisContainer 2>$null | Out-Null } }
    'verify'   { Verify }
}

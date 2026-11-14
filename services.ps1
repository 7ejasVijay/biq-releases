# BreakoutIQ server + database for Windows (the desktop app is installed separately with its installer).
# Requires: Docker Desktop for Windows (WSL2 backend recommended), running.
#
# Usage (run in PowerShell, in this folder):
#   .\services.ps1 up       - build the server and start the server + database (safe to run again)
#   .\services.ps1 down     - stop them; the data is kept
#   .\services.ps1 restart  - down then up
#   .\services.ps1 status   - show running containers
#   .\services.ps1 logs     - follow the server's log (Ctrl+C to stop following)
#   .\services.ps1 fresh    - wipe the database and images, then rebuild from scratch (asks first)
#   .\services.ps1 destroy  - remove the server and database completely: containers, database, images, secrets
#                             (asks first; the app itself is uninstalled from Windows Settings > Apps)
#
# First time, to allow the script to run:
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#
# Once Docker Desktop is set to start with Windows, the server and database start with it (restart: unless-stopped).

param(
    [Parameter(Position=0)]
    [ValidateSet("up","down","restart","status","logs","fresh","destroy")]
    [string]$Command = "status"
)

# ── Settings ──────────────────────────────────────────────────────────────────
# GitHub personal access token with read access to the breakoutiq-server repo (the server is built from it).
# Leave empty to use GITHUB_TOKEN from a .env file in this folder instead.
$GithubToken = ""

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComposeFile = Join-Path $ScriptDir "docker-compose.yml"
$EnvFile     = Join-Path $ScriptDir ".env"
$SecretsDir  = Join-Path $ScriptDir "secrets"
$Port        = 3001

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg"  -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "ERROR: $msg" -ForegroundColor Red }

# docker compose with this folder's compose file (and .env when there is one).
function Compose {
    $base = @("compose", "-f", $ComposeFile)
    if (Test-Path $EnvFile) { $base += @("--env-file", $EnvFile) }
    & docker @base @args
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err "Docker not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop"
        exit 1
    }
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker Desktop is not running. Please start it and try again."
        exit 1
    }
}

function Assert-Token {
    if ($GithubToken) { $env:GITHUB_TOKEN = $GithubToken; return }
    if ($env:GITHUB_TOKEN) { return }
    if ((Test-Path $EnvFile) -and (Select-String -Path $EnvFile -Pattern '^\s*GITHUB_TOKEN=\S' -Quiet)) { return }
    Write-Err "No GitHub token. Put it in `$GithubToken at the top of services.ps1 (or GITHUB_TOKEN=... in .env)."
    exit 1
}

function Confirm-Typed($word, $what) {
    Write-Host ""
    Write-Host $what -ForegroundColor Yellow
    $answer = Read-Host "Type $word to continue (anything else cancels)"
    if ($answer -cne $word) { Write-Ok "Cancelled. Nothing was changed."; exit 0 }
}

# 32 random bytes.
function New-RandomBytes {
    $b = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ,$b
}

# Written with "\n" line endings and no BOM, so Docker and the server read them cleanly.
function Write-PlainFile($path, [string[]]$lines) {
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

# The server's secrets: created once and kept, so nobody is signed out and saved broker logins stay readable.
function Initialize-Secrets {
    if (-not (Test-Path $SecretsDir)) { New-Item -ItemType Directory -Path $SecretsDir | Out-Null }

    $vault = Join-Path $SecretsDir "vault_keys"
    if (-not (Test-Path $vault) -or (Get-Item $vault).Length -eq 0) {
        Write-PlainFile $vault @("1:" + [Convert]::ToBase64String((New-RandomBytes)))
        Write-Ok "Created secrets\vault_keys (locks saved broker logins; deleting it makes them unreadable)"
    }

    $envPath = Join-Path $SecretsDir "server.env"
    if (-not (Test-Path $envPath)) {
        $hex = { -join ((New-RandomBytes) | ForEach-Object { $_.ToString("x2") }) }
        Write-PlainFile $envPath @(
            "JWT_SECRET=$(& $hex)",
            "ADMIN_SECRET=$(& $hex)",
            "ADMIN_JWT_SECRET=$(& $hex)",
            "# Password-reset emails: fill in a real mail account and run '.\services.ps1 restart'.",
            "# Until then, reset codes are printed in '.\services.ps1 logs'.",
            "#SMTP_HOST=smtp.gmail.com",
            "#SMTP_PORT=587",
            "#SMTP_USER=you@example.com",
            "#SMTP_PASS=app-password-here",
            "#SMTP_FROM=BreakoutIQ <you@example.com>"
        )
        Write-Ok "Created secrets\server.env"
    }
}

# Waits until the database answers 3 times in a row (it restarts once while initialising a new volume).
function Wait-Db {
    $ok = 0
    for ($i = 0; $i -lt 90; $i++) {
        $r = Compose exec -T db psql -U postgres -d breakoutiq -tAc "SELECT 1" 2>$null
        if ("$r".Trim() -eq "1") { $ok++; if ($ok -ge 3) { return $true } } else { $ok = 0 }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-Server {
    Write-Host "    Waiting for the server" -NoNewline
    for ($i = 0; $i -lt 120; $i++) {
        try {
            Invoke-WebRequest -Uri "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 2 | Out-Null
            Write-Host ""
            return $true
        } catch { Write-Host "." -NoNewline; Start-Sleep -Seconds 1 }
    }
    Write-Host ""
    return $false
}

# ── Commands ──────────────────────────────────────────────────────────────────

function Invoke-Up {
    Assert-Docker
    Assert-Token
    Initialize-Secrets

    Write-Step "Building the server (no cache, takes a few minutes)..."
    $env:DOCKER_BUILDKIT = "1"
    Compose build --no-cache server
    if ($LASTEXITCODE -ne 0) { Write-Err "Build failed. Check the output above for details."; exit 1 }

    Write-Step "Starting the database..."
    # --remove-orphans clears containers from older setups (client, scheduler, ollama).
    Compose up -d --wait --remove-orphans db
    if ($LASTEXITCODE -ne 0 -or -not (Wait-Db)) { Write-Err "The database did not start. See: docker logs breakoutiq-db"; exit 1 }

    # A brand-new database needs the base tables (strategies, companies, ...); the server adds the rest on start.
    $have = Compose exec -T db psql -U postgres -d breakoutiq -tAc "SELECT to_regclass('public.strategies') IS NOT NULL"
    if ("$have".Trim() -ne "t") {
        Write-Step "Creating the base tables..."
        # File copies, not a pipe: Windows PowerShell can hang piping one docker command into another.
        $tmp = Join-Path $env:TEMP "breakoutiq_base_schema.sql"
        Compose create --no-recreate server *> $null
        docker cp "breakoutiq-server:/usr/local/share/breakoutiq/base_schema.sql" $tmp
        if ($LASTEXITCODE -eq 0) { docker cp $tmp "breakoutiq-db:/tmp/base_schema.sql" }
        if ($LASTEXITCODE -eq 0) { Compose exec -T db psql -U postgres -d breakoutiq -q -v ON_ERROR_STOP=1 -f /tmp/base_schema.sql }
        if ($LASTEXITCODE -ne 0) { Write-Err "Could not create the base tables."; exit 1 }
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }

    Write-Step "Starting the server..."
    Compose up -d --force-recreate --remove-orphans server
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to start the server."; exit 1 }

    if (Wait-Server) {
        Write-Host ""
        Write-Step "Running:"
        Write-Ok "server  -> http://localhost:$Port"
        Write-Ok "db      -> localhost:5433"
        Write-Host ""
        Write-Host "    Now open the BreakoutIQ app and sign up / sign in." -ForegroundColor DarkGray
    } else {
        Write-Err "The server did not answer within 2 minutes. See '.\services.ps1 logs'."
        exit 1
    }
}

function Invoke-Down {
    Assert-Docker
    Write-Step "Stopping containers..."
    Compose down --remove-orphans
    Write-Ok "Stopped. Your data is kept; run '.\services.ps1 up' to start again."
}

function Invoke-Fresh {
    Assert-Docker
    Confirm-Typed "FRESH" "This deletes the database (all accounts and server data) and rebuilds the server."
    Write-Step "Wiping containers, volumes, and images..."
    Compose down -v --rmi all --remove-orphans
    Write-Ok "Removed."
    Invoke-Up
}

function Invoke-Destroy {
    Assert-Docker
    Confirm-Typed "DESTROY" ("This removes the BreakoutIQ server and database from this computer: containers, the database " +
        "(all accounts), images and the server secrets (saved broker logins become unreadable). It cannot be undone.")

    # Containers, volumes and images of this setup, including leftovers from older versions (e.g. Ollama).
    Write-Step "Removing the server, database and their images..."
    $project = (Compose config --format json | ConvertFrom-Json).name
    Compose down -v --rmi all --remove-orphans
    if ($project) {
        $vols = docker volume ls -q --filter "label=com.docker.compose.project=$project"
        if ($vols) { docker volume rm -f $vols | Out-Null }
    }
    docker image rm -f ollama/ollama 2>$null | Out-Null
    if (Test-Path $SecretsDir) { Remove-Item -Recurse -Force $SecretsDir }
    Write-Ok "Server, database, images and secrets removed."

    Write-Host ""
    Write-Ok "Done. The server and database are gone. (The app is uninstalled from Windows Settings > Apps; Docker Desktop is left installed.)"
}

function Invoke-Status {
    Assert-Docker
    Write-Step "Container status:"
    Compose ps
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

switch ($Command) {
    "up"      { Invoke-Up }
    "down"    { Invoke-Down }
    "restart" { Invoke-Down; Start-Sleep -Seconds 2; Invoke-Up }
    "status"  { Invoke-Status }
    "logs"    { Assert-Docker; Compose logs -f --tail=100 server }
    "fresh"   { Invoke-Fresh }
    "destroy" { Invoke-Destroy }
}

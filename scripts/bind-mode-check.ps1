<#
.SYNOPSIS
    Focused bind-mode check for compose.bind.yaml (README: "Bind mounts").

.DESCRIPTION
    The acceptance suite (scripts/smoke-test.sh) stays on named volumes. This
    script proves the same four trees work as host bind mounts: directories
    created by Docker, the root setup phase, the /data/home/.nanobot symlink,
    writes as nanobot, recreate and down/up persistence, the .ssh mode,
    channel dependencies cached in <Root>/data/cache, and that /data/brew stays
    the nanobot_brew named volume in bind mode.

    It chains the real compose.yaml + compose.bind.yaml and only moves the
    Compose project directory, so the `./data` sources resolve under -Root
    instead of the repository. An operator's live ./data is never touched.

    PowerShell rather than bash because this check has to hand Compose an
    absolute Windows path; the bash in this environment turns it into a POSIX
    path and the daemon then rejects the bind as an invalid volume
    specification.

    The check is destructive for "<Root>/data": it empties it first and again on
    exit, and refuses to start when that directory already holds files, so pass
    -Force only for a scratch copy.

.EXAMPLE
    pwsh -File scripts/bind-mode-check.ps1 -Root "$env:TEMP\nanobot-bind"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Root,
    [string]$Image = "nanobot-pixi:smoke",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$bindRoot = $Root.TrimEnd("\", "/")
$dataDir = Join-Path $bindRoot "data"
$project = "nanobot-bind-$PID"
$container = "$project-nanobot"

$script:passed = 0
$script:section = 1
$script:failed = 0
$script:warned = 0
$script:cid = $null

function Pass([string]$message) {
    Write-Host ("B{0,-2} PASS  {1}" -f $script:section, $message)
    $script:passed++
}
function Fail([string]$message) {
    Write-Host ("B{0,-2} FAIL  {1}" -f $script:section, $message) -ForegroundColor Red
    $script:failed++
}
function Warn([string]$message) {
    Write-Host ("B{0,-2} WARN  {1}" -f $script:section, $message) -ForegroundColor Yellow
    $script:warned++
}
function AssertEq([string]$desc, $expected, $actual) {
    if ("$expected" -eq "$actual") { Pass $desc }
    else { Fail ("{0} (expected [{1}], got [{2}])" -f $desc, $expected, $actual) }
}
function AssertContains([string]$desc, [string]$haystack, [string]$needle) {
    if ($haystack -and $haystack.Contains($needle)) { Pass $desc }
    else { Fail ("{0} (missing [{1}])" -f $desc, $needle) }
}

function Invoke-Docker {
    param([string[]]$DockerArgs)
    # Native stderr becomes an ErrorRecord under EAP=Stop; the checks below
    # assert on exit codes, so capture stderr and keep going.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & docker @DockerArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Output = ($output -join "`n"); Code = $code }
}

function Compose {
    param([string[]]$ComposeArgs)
    $all = @("compose", "-p", $project, "-f", "compose.yaml", "-f", "compose.bind.yaml",
        "-f", "scripts/smoke-compose.yaml") + $ComposeArgs
    return Invoke-Docker $all
}

function Exec-Nanobot {
    param([string[]]$ExecArgs)
    return Invoke-Docker (@("exec", "-u", "nanobot", $script:cid) + $ExecArgs)
}

function Get-Health {
    if (-not $script:cid) { return "none" }
    $result = Invoke-Docker @("inspect", "-f",
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", $script:cid)
    return $result.Output.Trim()
}

function Start-Stack {
    param([switch]$Recreate)
    $extra = @()
    if ($Recreate) { $extra = @("--force-recreate") }
    $up = Compose (@("up", "-d") + $extra + @("--wait", "--wait-timeout", "300"))
    if ($up.Code -ne 0) {
        Write-Host $up.Output
        throw "compose up failed"
    }
    $ps = Compose @("ps", "-q", "nanobot")
    $script:cid = $ps.Output.Trim()
    if (-not $script:cid) { throw "compose did not report a container id" }
}

function Stop-Stack {
    Compose @("down", "--remove-orphans") | Out-Null
    if ($script:cid) { Invoke-Docker @("rm", "-f", $script:cid) | Out-Null }
    Invoke-Docker @("network", "rm", "${project}_default") | Out-Null
    if (Test-Path $dataDir) { Remove-Item -Recurse -Force $dataDir }
    Remove-Item -Force (Join-Path $bindRoot "compose.yaml") -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $bindRoot "compose.bind.yaml") -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $bindRoot "scripts") -ErrorAction SilentlyContinue
}

$env:NANOBOT_IMAGE = $Image
$env:NANOBOT_SMOKE_CONTAINER = $container
$env:NANOBOT_WEB_PORT = "18768"
$env:NANOBOT_HEALTH_HOST_PORT = "18793"
$env:NANOBOT_HEALTH_PORT = "18790"
$env:NANOBOT_WEB_TOKEN = "bind-mode-check-token"
$env:NANOBOT_CHANNELS = "discord"
$env:TZ = "UTC"

try {
    $script:section = 1
    Write-Host "`n=== B1: prerequisites ==="
    $info = Invoke-Docker @("info")
    if ($info.Code -ne 0) { throw "Docker daemon is not reachable" }
    $imageCheck = Invoke-Docker @("image", "inspect", $Image)
    if ($imageCheck.Code -ne 0) { throw "image $Image is missing; build it with: docker build -t $Image ." }

    $resolved = [System.IO.Path]::GetFullPath($bindRoot)
    if ($resolved -eq $repo -or $resolved.StartsWith($repo + "\") -or $resolved.StartsWith($repo + "/")) {
        throw "the scratch root must be outside the repository (got $resolved)"
    }
    if ((Test-Path $dataDir) -and (Get-ChildItem -Force $dataDir | Select-Object -First 1) -and -not $Force) {
        throw "$dataDir is not empty; refusing to delete it (pass -Force for a scratch copy)"
    }

    if (Test-Path $dataDir) { Remove-Item -Recurse -Force $dataDir }
    New-Item -ItemType Directory -Force -Path (Join-Path $bindRoot "scripts") | Out-Null
    Copy-Item (Join-Path $repo "compose.yaml") $bindRoot -Force
    Copy-Item (Join-Path $repo "compose.bind.yaml") $bindRoot -Force
    Copy-Item (Join-Path $repo "scripts\smoke-compose.yaml") (Join-Path $bindRoot "scripts") -Force
    Push-Location $bindRoot
    Pass "starting from an empty $dataDir"

    $script:section = 2

    Write-Host "`n=== B2: fresh bind mounts created by Docker ==="
    Start-Stack
    AssertEq "container is healthy with fresh host directories" "healthy" (Get-Health)

    $mounts = (Invoke-Docker @("inspect", "-f",
            '{{range .Mounts}}{{.Type}} {{.Destination}} rw={{.RW}};{{end}}', $script:cid)).Output
    foreach ($target in @("/data/config", "/data/home", "/data/pixi", "/data/cache")) {
        AssertContains "$target is a read-write bind mount" $mounts "bind $target rw=true"
    }
    $mountJson = (Invoke-Docker @("inspect", "-f", "{{json .Mounts}}", $script:cid)).Output
    $volumeTargets = @()
    if ($mountJson) {
        $volumeTargets = @($mountJson | ConvertFrom-Json |
                Where-Object { $_.Type -eq "volume" -and $_.Destination -like "/data*" } |
                ForEach-Object { $_.Destination })
    }
    # /data/brew is the one deliberate named volume in bind mode: Homebrew's git
    # checkout and bottle unpacking must not run on a 9p bind (see README).
    AssertEq "the only named volume under /data is /data/brew" "/data/brew" ($volumeTargets -join ",")
    AssertContains "/data/brew is a volume, not a bind" $mounts "volume /data/brew rw=true"
    AssertEq "brew resolves inside the bind-mode stack" "/data/brew" (Exec-Nanobot @("brew", "--prefix")).Output.Trim()
    foreach ($dir in @("config", "home", "pixi", "cache")) {
        if (Test-Path (Join-Path $dataDir $dir)) { Pass "./data/$dir exists on the host" }
        else { Fail "./data/$dir exists on the host" }
    }
    if (Test-Path (Join-Path $dataDir "config\config.json")) {
        Pass "config.json was bootstrapped into ./data/config"
    }
    else { Fail "config.json was bootstrapped into ./data/config" }
    if (Test-Path (Join-Path $dataDir "config\workspace")) {
        Pass "the workspace directory is on the host"
    }
    else { Fail "the workspace directory is on the host" }

    $script:section = 3

    Write-Host "`n=== B3: symlink and writes as nanobot ==="
    AssertEq "/data/home/.nanobot resolves to /data/config" "/data/config" (Exec-Nanobot @("readlink","-f","/data/home/.nanobot")).Output.Trim()
    AssertContains "the symlink survives on the bind" (Exec-Nanobot @("ls","-l","/data/home/.nanobot")).Output "-> /data/config"
    foreach ($tree in @("config", "home", "pixi", "cache")) {
        $touch = Exec-Nanobot @("touch", "/data/$tree/bind-write.txt")
        $test = Exec-Nanobot @("test", "-f", "/data/$tree/bind-write.txt")
        if ($touch.Code -eq 0 -and $test.Code -eq 0) { Pass "nanobot can write in /data/$tree" }
        else { Fail "nanobot can write in /data/$tree" }
    }
    if (Test-Path (Join-Path $dataDir "pixi\bind-write.txt")) { Pass "the writes are visible on the host" }
    else { Fail "the writes are visible on the host" }

    $script:section = 4

    Write-Host "`n=== B4: recreate ==="
    Exec-Nanobot @("mkdir","-p","/data/home/.ssh") | Out-Null
    Exec-Nanobot @("chmod","700","/data/home/.ssh") | Out-Null
    AssertEq ".ssh is mode 700 inside the container" "700" (Exec-Nanobot @("stat","-c","%a","/data/home/.ssh")).Output.Trim()
    Exec-Nanobot @("sh","-c","echo bind-session > /data/config/sessions/bind-marker.txt") | Out-Null
    Start-Stack -Recreate
    AssertEq "container is healthy after recreate" "healthy" (Get-Health)
    AssertEq "symlink survives a recreate" "/data/config" (Exec-Nanobot @("readlink","-f","/data/home/.nanobot")).Output.Trim()
    AssertEq "sessions marker survives a recreate" "0" (Exec-Nanobot @("test","-f","/data/config/sessions/bind-marker.txt")).Code
    AssertEq "bind-write markers survive a recreate" "0" (Exec-Nanobot @("test","-f","/data/pixi/bind-write.txt")).Code
    $mode = (Exec-Nanobot @("stat","-c","%a","/data/home/.ssh")).Output.Trim()
    if ($mode -eq "700") { Pass ".ssh keeps mode 700 after a recreate" }
    else { Warn ".ssh mode is $mode after a recreate (Docker Desktop does not always keep Unix modes on a Windows bind; named volumes are unaffected)" }

    $script:section = 5

    Write-Host "`n=== B5: down + up persistence ==="
    $tokenCount = (Exec-Nanobot @("sh","-c","grep -c bind-mode-check-token /data/config/config.json")).Output.Trim()
    Compose @("down", "--remove-orphans") | Out-Null
    $script:cid = $null
    Start-Stack
    AssertEq "container is healthy after down + up" "healthy" (Get-Health)
    AssertEq "config.json still carries the bootstrap token" $tokenCount (Exec-Nanobot @("sh","-c","grep -c bind-mode-check-token /data/config/config.json")).Output.Trim()
    AssertEq "sessions marker survived down + up" "0" (Exec-Nanobot @("test","-f","/data/config/sessions/bind-marker.txt")).Code
    AssertEq "config write marker survived down + up" "0" (Exec-Nanobot @("test","-f","/data/config/bind-write.txt")).Code

    $script:section = 6

    Write-Host "`n=== B6: channel dependencies and cache ==="
    $logs = (Invoke-Docker @("logs", $script:cid)).Output
    AssertContains "startup installed the channel dependencies" $logs "installed channel dependencies for: discord"
    AssertEq "discord imports from /app/.venv" "0" (Exec-Nanobot @("/app/.venv/bin/python","-c","import discord")).Code
    if (Test-Path (Join-Path $dataDir "cache\uv")) { Pass "the uv cache is on the host under ./data/cache/uv" }
    else { Fail "the uv cache is on the host under ./data/cache/uv" }
}
catch {
    Fail $_.Exception.Message
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Stop-Stack
}

Write-Host "`n=== summary ==="
Write-Host ("passed checks: {0}" -f $script:passed)
Write-Host ("warnings: {0}" -f $script:warned)
Write-Host ("failed checks: {0}" -f $script:failed)
if ($script:failed -ne 0) { exit 1 }
Write-Host "BIND MODE CHECKS PASSED"

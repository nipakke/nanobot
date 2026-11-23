#!/usr/bin/env bash
# End-to-end smoke test suite for the nanobot + pixi image.
#
# Builds nanobot-pixi:smoke (or tests an existing image when
# NANOBOT_SMOKE_SKIP_BUILD=1), runs it through Compose with five fresh,
# initially root-owned named volumes, and verifies entrypoint privilege drop,
# persistence, pixi, healthcheck, bootstrap, symlink safety, upgrade rejection,
# channel dependency installs, Homebrew on its own volume, npm global prefix,
# and workspace AGENTS.md rules.
# Uses a unique Compose project name and removes only the resources it creates.
set -uo pipefail

cd "$(dirname "$0")/.."

readonly IMAGE="${NANOBOT_SMOKE_IMAGE:-nanobot-pixi:smoke}"
# NANOBOT_SMOKE_SKIP_BUILD=1 tests an image that is already present (CI builds
# it once, tests it, and pushes exactly that image) instead of building one.
readonly SKIP_BUILD="${NANOBOT_SMOKE_SKIP_BUILD:-0}"
readonly PROJECT="nanobot-smoke-$$"
# compose.yml pins `container_name: nanobot` for operators. The suite passes
# scripts/smoke-compose.yml last to override it, so an operator's `nanobot`
# container is never taken over (or removed by `down --remove-orphans`).
readonly CONTAINER_NAME="${PROJECT}-nanobot"
readonly BOOTSTRAP_NAME="${PROJECT}-bootstrap"
readonly BUILD_LOG="${TMPDIR:-/tmp}/nanobot-smoke-build.log"

# Expected versions come from the Dockerfile ARG defaults, the single source of
# version pins, so a Renovate bump is checked against what it intended.
dockerfile_arg() {
    sed -n "s/^ARG $1=//p" Dockerfile | head -n 1 | tr -d '\r'
}
EXPECTED_NANOBOT_VERSION="$(dockerfile_arg NANOBOT_VERSION)"
EXPECTED_PIXI_VERSION="$(dockerfile_arg PIXI_VERSION)"
EXPECTED_BREW_VERSION="$(dockerfile_arg BREW_VERSION)"
readonly EXPECTED_NANOBOT_VERSION EXPECTED_PIXI_VERSION EXPECTED_BREW_VERSION
if [ -z "$EXPECTED_NANOBOT_VERSION" ] || [ -z "$EXPECTED_PIXI_VERSION" ] || [ -z "$EXPECTED_BREW_VERSION" ]; then
    printf 'FATAL: could not read NANOBOT_VERSION/PIXI_VERSION/BREW_VERSION defaults from Dockerfile\n' >&2
    exit 1
fi

export NANOBOT_SMOKE_CONTAINER="$CONTAINER_NAME"
COMPOSE=(docker compose -p "$PROJECT" \
    -f compose.yml \
    -f compose.build.yml \
    -f scripts/smoke-compose.yml)
CID=""
PASSED=0
FAILED=0
SECTION="init"

VOLUMES=(
    "${PROJECT}_nanobot_config"
    "${PROJECT}_nanobot_home"
    "${PROJECT}_nanobot_pixi"
    "${PROJECT}_nanobot_cache"
    "${PROJECT}_nanobot_brew"
)
EXTRA_VOLUMES=(
    "${PROJECT}_sym_config"
    "${PROJECT}_sym_home"
    "${PROJECT}_sym_pixi"
    "${PROJECT}_sym_cache"
    "${PROJECT}_sym_home2"
    "${PROJECT}_sym_home3"
    "${PROJECT}_sym_config3"
    "${PROJECT}_single_data"
)

section() {
    SECTION="$1"
    printf '\n=== %s ===\n' "$2"
}
pass() { printf '[%-10s] PASS  %s\n' "$SECTION" "$1"; PASSED=$((PASSED + 1)); }
fail() {
    printf '[%-10s] FAIL  %s\n' "$SECTION" "$1" >&2
    FAILED=$((FAILED + 1))
}
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc (expected [$expected], got [$actual])"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        pass "$desc"
    else
        fail "$desc (missing [$needle])"
    fi
}

assert_nonzero_status() {
    local desc="$1" rc="$2"
    if [ "$rc" -ne 0 ]; then
        pass "$desc"
    else
        fail "$desc (expected nonzero exit, got 0)"
    fi
}

cleanup() {
    set +e
    "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1
    docker rm -f "$BOOTSTRAP_NAME" >/dev/null 2>&1
    # Anything else this project created: `compose run` one-offs get random
    # names unless the suite passes --name, so sweep the project label too.
    local id
    while IFS= read -r id; do
        [ -n "$id" ] && docker rm -f "$id" >/dev/null 2>&1
    done < <(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}")
    local name
    while IFS= read -r name; do
        [ -n "$name" ] && docker rm -f "$name" >/dev/null 2>&1
    done < <(docker ps -a --format '{{.Names}}' | grep -E "^${PROJECT}-" || true)
    local volume
    for volume in "${VOLUMES[@]}" "${EXTRA_VOLUMES[@]}"; do
        docker volume rm -f "$volume" >/dev/null 2>&1
    done
    docker network rm "${PROJECT}_default" >/dev/null 2>&1
}
trap cleanup EXIT

health_status() {
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$CID" 2>/dev/null || true
}

wait_healthy() {
    local deadline=$((SECONDS + 240)) status
    while [ "$SECONDS" -lt "$deadline" ]; do
        status="$(health_status)"
        [ "$status" = "healthy" ] && return 0
        if [ "$(docker inspect -f '{{.State.Status}}' "$CID" 2>/dev/null || echo missing)" = "exited" ]; then
            docker logs --tail 80 "$CID" >&2 2>&1
            return 1
        fi
        sleep 2
    done
    docker logs --tail 80 "$CID" >&2 2>&1
    return 1
}

exec_nanobot() { docker exec -u nanobot "$CID" "$@"; }
exec_root() { docker exec -u 0 "$CID" "$@"; }

# Docker Desktop can briefly return "No such container" during a restart race.
exec_nanobot_retry() {
    local out rc i
    for i in $(seq 1 30); do
        out="$(docker exec -u nanobot "$CID" "$@" 2>&1)"
        rc=$?
        [ "$rc" -eq 0 ] && { printf '%s' "$out"; return 0; }
        case "$out" in
            *"No such container"*|*"is restarting"*|*"is not running"*) sleep 1 ;;
            *) printf '%s' "$out"; return "$rc" ;;
        esac
    done
    printf '%s' "$out"
    return "$rc"
}

# Run a long install detached and poll for its exit code.
#
# Homebrew and npm installs produce no output until they finish, and Docker
# Desktop can drop a long silent `docker exec` stream with HTTP 500 while the
# container keeps running. Detaching keeps the work alive, keeps the suite's
# output moving (a dot per poll), and makes a broken CLI stream harmless.
# Sets DETACHED_RC (empty on timeout) and DETACHED_SECONDS.
DETACHED_RC=""
DETACHED_SECONDS=0
run_detached() {
    local label="$1" command="$2" limit="$3" waited=0 rc=""

    exec_nanobot rm -f /tmp/smoke-cmd.rc /tmp/smoke-cmd.log >/dev/null 2>&1
    docker exec -d -u nanobot "$CID" sh -c \
        "{ $command ; } >/tmp/smoke-cmd.log 2>&1; echo \$? >/tmp/smoke-cmd.rc" >/dev/null 2>&1
    printf '%s: ' "$label"
    while [ "$waited" -lt "$limit" ]; do
        rc="$(exec_nanobot sh -c 'cat /tmp/smoke-cmd.rc 2>/dev/null' 2>/dev/null || true)"
        [ -n "$rc" ] && break
        printf '.'
        sleep 5
        waited=$((waited + 5))
    done
    printf ' %ss rc=%s\n' "$waited" "${rc:-timeout}"
    exec_nanobot tail -2 /tmp/smoke-cmd.log 2>/dev/null || true
    DETACHED_RC="$rc"
    DETACHED_SECONDS="$waited"
}

start_service() {
    "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 300
    CID="$("${COMPOSE[@]}" ps -q nanobot)"
    [ -n "$CID" ] || fatal "compose did not report a container id"
}

force_recreate() {
    "${COMPOSE[@]}" up -d --no-build --force-recreate --wait --wait-timeout 300
    CID="$("${COMPOSE[@]}" ps -q nanobot)"
    [ -n "$CID" ] || fatal "compose did not report a container id after recreate"
}

restart_service() {
    "${COMPOSE[@]}" restart nanobot >/dev/null
    wait_healthy || fatal "container did not become healthy after restart"
}

docker_daemon_ok() { docker info >/dev/null 2>&1; }

docker_daemon_ok || fatal "Docker daemon is not reachable"
command -v docker >/dev/null || fatal "docker CLI is missing"

printf 'project=%s container=%s image=%s\n' "$PROJECT" "$CONTAINER_NAME" "$IMAGE"

# ---------------------------------------------------------------------------
# Build and image metadata
# ---------------------------------------------------------------------------
section build "Build and image metadata"
if [ "$SKIP_BUILD" = "1" ]; then
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        pass "prebuilt image $IMAGE is present (NANOBOT_SMOKE_SKIP_BUILD=1)"
    else
        fail "prebuilt image $IMAGE is present (NANOBOT_SMOKE_SKIP_BUILD=1)"
        exit 1
    fi
elif docker build -t "$IMAGE" . >"$BUILD_LOG" 2>&1; then
    pass "docker build -t $IMAGE ."
    tail -5 "$BUILD_LOG"
else
    fail "docker build -t $IMAGE ."
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi

image_user="$(docker image inspect -f '{{.Config.User}}' "$IMAGE")"
assert_eq "image user is root for the setup phase" "root" "$image_user"
entrypoint_json="$(docker image inspect -f '{{json .Config.Entrypoint}}' "$IMAGE")"
assert_contains "image entrypoint wraps the script with tini" "$entrypoint_json" '"/usr/bin/tini"'
assert_contains "image entrypoint runs entrypoint.sh" "$entrypoint_json" '"/usr/local/bin/entrypoint.sh"'

# ---------------------------------------------------------------------------
# Startup: pre-create the five volumes root-owned, then start with exact caps.
# ---------------------------------------------------------------------------
section startup "Fresh root-owned volumes and capabilities"
for volume in "${VOLUMES[@]}"; do
    docker volume create "$volume" >/dev/null || fatal "could not create $volume"
done

# Host ports are distinct from the operator defaults (8765, 18790) so the suite
# can run next to a live stack; the container-side ports stay 8765 and 18790.
# Both host ports are overridable on hosts where the defaults are unavailable:
# NANOBOT_SMOKE_WEB_PORT and NANOBOT_SMOKE_HEALTH_PORT.
WEB_HOST_PORT="${NANOBOT_SMOKE_WEB_PORT:-18766}"
HEALTH_HOST_PORT="${NANOBOT_SMOKE_HEALTH_PORT:-18791}"

export NANOBOT_IMAGE="$IMAGE"
export NANOBOT_BUILD_IMAGE="$IMAGE"
export EXTRA_PIXI_PACKAGES="jq,ripgrep,nodejs"
export TZ="UTC"
export NANOBOT_WEB_TOKEN="smoke-web-token"
export NANOBOT_SMOKE_WEB_PORT="$WEB_HOST_PORT"
export NANOBOT_SMOKE_HEALTH_PORT="$HEALTH_HOST_PORT"

if "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 300; then
    pass "startup fixes ownership on fresh root-owned volumes and becomes healthy"
else
    fail "startup on fresh root-owned volumes"
    "${COMPOSE[@]}" logs --no-color --tail 100 nanobot >&2 || true
    exit 1
fi
CID="$("${COMPOSE[@]}" ps -q nanobot)"
[ -n "$CID" ] || fatal "compose did not report a container id"

cap_drop="$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$CID")"
cap_add="$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$CID")"
security_opt="$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$CID")"
assert_eq "cap_drop is exactly ALL" '["ALL"]' "$cap_drop"
for cap in CHOWN DAC_OVERRIDE SETUID SETGID; do
    if printf '%s' "$cap_add" | grep -Eq "\"(CAP_)?${cap}\""; then
        pass "cap_add includes $cap"
    else
        fail "cap_add includes $cap (got $cap_add)"
    fi
done
cap_count="$(printf '%s' "$cap_add" | grep -o '"' | wc -l)"
assert_eq "cap_add has exactly four entries" "8" "$cap_count"
assert_contains "no-new-privileges is enabled" "$security_opt" 'no-new-privileges:true'
entrypoint_body="$(exec_root cat /usr/local/bin/entrypoint.sh)"
assert_contains "entrypoint uses the mismatched-owner find scan" "$entrypoint_body" \
    '! -uid "$NANOBOT_UID"'
if printf '%s' "$entrypoint_body" | grep -Fq "chown -R"; then
    fail "entrypoint does not run an unconditional recursive chown"
else
    pass "entrypoint does not run an unconditional recursive chown"
fi

# ---------------------------------------------------------------------------
# Unprivileged identity
# ---------------------------------------------------------------------------
section identity "Unprivileged identity"
assert_eq "id -u is 1000" "1000" "$(exec_nanobot id -u)"
assert_eq "id -g is 1000" "1000" "$(exec_nanobot id -g)"
assert_eq "command -v sudo is empty" "" "$(exec_nanobot sh -c 'command -v sudo || true')"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
section env "Environment variables and PATH"
for pair in \
    HOME=/data/home \
    NANOBOT_HOME=/data/config \
    PIXI_HOME=/data/pixi \
    PIXI_CACHE_DIR=/data/cache/pixi \
    XDG_CACHE_HOME=/data/cache \
    UV_CACHE_DIR=/data/cache/uv \
    UV_TOOL_DIR=/data/home/.local/share/uv/tools \
    UV_TOOL_BIN_DIR=/data/home/.local/bin \
    PIP_CACHE_DIR=/data/cache/pip \
    PYTHONPYCACHEPREFIX=/data/cache/pycache \
    PIXI_NO_TELEMETRY=1; do
    var="${pair%%=*}"
    expected="${pair#*=}"
    assert_eq "$var is $expected" "$expected" "$(exec_nanobot printenv "$var" || true)"
done
path_value="$(exec_nanobot printenv PATH || true)"
case "$path_value" in
    /data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin:*) pass "PATH starts with pixi, home bin, brew, venv" ;;
    *) fail "PATH starts with pixi, home bin, brew, venv (got [$path_value])" ;;
esac

# ---------------------------------------------------------------------------
# Tool versions
# ---------------------------------------------------------------------------
section versions "Installed tool versions"
nanobot_version="$(exec_nanobot sh -c 'nanobot --version' 2>&1)"
pixi_version="$(exec_nanobot sh -c 'pixi --version' 2>&1)"
uv_version="$(exec_nanobot sh -c 'uv --version' 2>&1)"
tini_version="$(exec_nanobot sh -c 'tini --version' 2>&1)"
unzip_version="$(exec_nanobot unzip -v 2>&1)"
assert_contains "nanobot --version" "$nanobot_version" "$EXPECTED_NANOBOT_VERSION"
assert_contains "pixi --version" "$pixi_version" "${EXPECTED_PIXI_VERSION#v}"
assert_contains "uv --version" "$uv_version" "uv "
assert_contains "tini --version" "$tini_version" "tini version"
assert_contains "unzip is installed" "$unzip_version" "UnZip"

# ---------------------------------------------------------------------------
# Persistent trees, venv, and image hygiene
# ---------------------------------------------------------------------------
section filesystem "Filesystem layout and ownership"
for dir in /data/config /data/home /data/pixi /data/cache \
    /data/cache/pixi /data/cache/uv /data/cache/pip /data/cache/pycache \
    /data/config/workspace /data/home/.local/bin /data/home/.local/share/uv/tools; do
    owner="$(exec_root stat -c '%u:%g' "$dir" 2>/dev/null || echo missing)"
    assert_eq "$dir exists and is owned 1000:1000 after startup" "1000:1000" "$owner"
done
image_tree_owners="$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
for d in /data/home/.local/bin /data/home/.local/share/uv/tools; do
    stat -c "%n %u:%g" "$d"
done
printf "pyc=%s\n" "$(find /app/.venv -type f -name "*.pyc" -print -quit)"
printf "tui=%s\n" "$(find /app/.venv/lib/python3.12/site-packages/nanobot/tui/bin -maxdepth 1 -type f -name "nanobot-tui-linux-*" -print -quit 2>/dev/null || true)"
' 2>&1)"
assert_contains "/data/home/.local/bin is 1000:1000 in the built image" \
    "$image_tree_owners" "/data/home/.local/bin 1000:1000"
assert_contains "/data/home/.local/share/uv/tools is 1000:1000 in the built image" \
    "$image_tree_owners" "/data/home/.local/share/uv/tools 1000:1000"
if printf '%s\n' "$image_tree_owners" | grep -qx 'pyc='; then
    pass "built image has zero .pyc files in /app/.venv"
else
    fail "built image has zero .pyc files in /app/.venv (got [$image_tree_owners])"
fi
if printf '%s\n' "$image_tree_owners" | grep -qx 'tui='; then
    pass "default built image omits bundled native TUI binary"
else
    fail "default built image omits bundled native TUI binary (got [$image_tree_owners])"
fi
assert_eq "/app/.venv is writable by nanobot" "0" \
    "$(exec_nanobot sh -c 'test -w /app/.venv' >/dev/null 2>&1; echo $?)"
assert_eq "bwrap is absent" "" "$(exec_nanobot sh -c 'command -v bwrap || true')"
mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CID")"
assert_contains "config volume mounted at /data/config" "$mounts" "/data/config"
assert_contains "home volume mounted at /data/home" "$mounts" "/data/home"
assert_contains "pixi volume mounted at /data/pixi" "$mounts" "/data/pixi"
assert_contains "cache volume mounted at /data/cache" "$mounts" "/data/cache"
case " $mounts " in
    *" /app "*) fail "/app is not mounted over" ;;
    *) pass "/app (including .venv) is not mounted over" ;;
esac

# ---------------------------------------------------------------------------
# PID 1 and gateway process user
# ---------------------------------------------------------------------------
section process "PID 1 and gateway process user"
assert_eq "PID 1 is tini" "tini" "$(exec_root cat /proc/1/comm 2>/dev/null || echo missing)"
gateway_status="$(exec_root sh -c '
for p in /proc/[0-9]*; do
    if [ "$(cat "$p/comm" 2>/dev/null)" = "nanobot-gateway" ]; then
        echo "found"
        grep -E "^(Uid|CapEff):" "$p/status"
        break
    fi
done
' 2>/dev/null)"
assert_contains "gateway process is nanobot-gateway" "$gateway_status" "found"
assert_contains "gateway process uid is 1000" "$gateway_status" $'Uid:\t1000'
assert_contains "gateway process has no effective capabilities" "$gateway_status" \
    $'CapEff:\t0000000000000000'
assert_contains "uid 1000 resolves to nanobot" \
    "$(exec_root getent passwd 1000 2>/dev/null || true)" "nanobot"
top_output="$(docker top "$CID" -o pid,user,args 2>/dev/null || true)"
assert_contains "docker top shows the gateway as nanobot/1000" "$top_output" "nanobot-gateway"
printf '%s\n' "$top_output" | sed -n '1,5p'

# ---------------------------------------------------------------------------
# ~/.nanobot symlink
# ---------------------------------------------------------------------------
section symlink "Config symlink"
assert_eq "/data/home/.nanobot resolves to /data/config" "/data/config" \
    "$(exec_nanobot readlink -f /data/home/.nanobot)"
assert_eq "the symlink is owned by 1000:1000" "1000:1000" \
    "$(exec_root stat -c '%u:%g' /data/home/.nanobot)"

# ---------------------------------------------------------------------------
# nanobot status canonical config path
# ---------------------------------------------------------------------------
section status "nanobot status path"
status_output="$(exec_nanobot sh -c 'nanobot status' 2>&1 || true)"
assert_contains "nanobot status names /data/config/config.json" \
    "$status_output" "/data/config/config.json"

# ---------------------------------------------------------------------------
# Generated config defaults
# ---------------------------------------------------------------------------
section config "Generated config defaults"
config_fields="$(exec_nanobot /app/.venv/bin/python -c '
import json
c = json.load(open("/data/config/config.json"))
print(c["agents"]["defaults"]["workspace"])
print(c["gateway"]["host"])
w = c["channels"]["websocket"]
print(w["host"])
print(w["port"])
print(c["tools"]["exec"]["pathPrepend"])
required = {
    "PIXI_HOME", "PIXI_CACHE_DIR", "PIXI_NO_TELEMETRY", "XDG_CACHE_HOME",
    "UV_CACHE_DIR", "UV_LINK_MODE", "PIP_CACHE_DIR", "PYTHONPYCACHEPREFIX",
    "NANOBOT_HOME", "TZ",
}
print(required.issubset(set(c["tools"]["exec"]["allowedEnvKeys"])))
' 2>&1)"
workspace_line="$(printf '%s\n' "$config_fields" | sed -n '1p')"
gateway_host_line="$(printf '%s\n' "$config_fields" | sed -n '2p')"
ws_host_line="$(printf '%s\n' "$config_fields" | sed -n '3p')"
ws_port_line="$(printf '%s\n' "$config_fields" | sed -n '4p')"
exec_path_line="$(printf '%s\n' "$config_fields" | sed -n '5p')"
exec_env_line="$(printf '%s\n' "$config_fields" | sed -n '6p')"
assert_eq "agents.defaults.workspace is /data/config/workspace" \
    "/data/config/workspace" "$workspace_line"
assert_eq "gateway.host is 0.0.0.0" "0.0.0.0" "$gateway_host_line"
assert_eq "websocket host is 0.0.0.0" "0.0.0.0" "$ws_host_line"
assert_eq "websocket port is 8765" "8765" "$ws_port_line"
assert_eq "tools.exec.pathPrepend names the image tool dirs" \
    "/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin" "$exec_path_line"
assert_eq "tools.exec.allowedEnvKeys forwards image layout, cache, telemetry, and TZ vars" \
    "True" "$exec_env_line"

# ---------------------------------------------------------------------------
# pixi extras in isolated environments
# ---------------------------------------------------------------------------
section pixi "EXTRA_PIXI_PACKAGES isolated environments"
assert_contains "jq --version works" \
    "$(exec_nanobot sh -c 'jq --version' 2>&1)" "jq-"
rg_version="$(exec_nanobot sh -c 'rg --version' 2>&1)"
assert_contains "rg --version works" "$rg_version" "ripgrep"
assert_eq "/data/pixi/envs/jq exists" "0" \
    "$(exec_nanobot test -d /data/pixi/envs/jq >/dev/null 2>&1; echo $?)"
assert_eq "/data/pixi/envs/ripgrep exists" "0" \
    "$(exec_nanobot test -d /data/pixi/envs/ripgrep >/dev/null 2>&1; echo $?)"
assert_eq "no shared /data/pixi/envs/extra environment" "1" \
    "$(exec_nanobot test -e /data/pixi/envs/extra >/dev/null 2>&1; echo $?)"
pixi_list="$(exec_nanobot sh -c 'pixi global list' 2>&1)"
assert_contains "pixi global list shows jq" "$pixi_list" "jq"
assert_contains "pixi global list shows ripgrep" "$pixi_list" "ripgrep"

# ---------------------------------------------------------------------------
# Idempotent pixi extras on restart
# ---------------------------------------------------------------------------
section pixi-idem "EXTRA_PIXI_PACKAGES idempotency on restart"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
restart_service
restart_logs="$(docker logs --since "$since" "$CID" 2>&1 || true)"
assert_contains "jq already present on restart" "$restart_logs" "pixi package 'jq' already present"
assert_contains "ripgrep already present on restart" "$restart_logs" "pixi package 'ripgrep' already present"
if printf '%s' "$restart_logs" | grep -Fq "installing pixi package"; then
    fail "no pixi install on restart"
else
    pass "no pixi install on restart"
fi

# ---------------------------------------------------------------------------
# Restricted .ssh directory survives restart and recreate
# ---------------------------------------------------------------------------
section ssh "Restricted 0700 .ssh directory"
exec_root mkdir -p /data/home/.ssh
exec_root chmod 700 /data/home/.ssh
exec_root chown 1000:1000 /data/home/.ssh
assert_eq ".ssh starts at 700 1000:1000" "700 1000:1000" \
    "$(exec_root stat -c '%a %u:%g' /data/home/.ssh)"
restart_service
assert_eq "restart succeeds and keeps .ssh at 700 1000:1000" "700 1000:1000" \
    "$(exec_nanobot_retry stat -c '%a %u:%g' /data/home/.ssh)"
force_recreate
assert_eq "force-recreate succeeds and keeps .ssh at 700 1000:1000" "700 1000:1000" \
    "$(exec_nanobot_retry stat -c '%a %u:%g' /data/home/.ssh)"
startup_logs="$(docker logs "$CID" 2>&1 | grep -iE 'permission denied|operation not permitted' || true)"
assert_eq "ownership scan did not hit permission errors" "" "$startup_logs"

# ---------------------------------------------------------------------------
# Persistence across force-recreate
# ---------------------------------------------------------------------------
section persist "Force-recreate persistence"
exec_nanobot sh -c 'echo home-marker > /data/home/marker-home'
exec_nanobot sh -c 'echo workspace-marker > /data/config/workspace/marker-workspace'
token_before="$(exec_nanobot /app/.venv/bin/python -c '
import json
print(json.load(open("/data/config/config.json"))["channels"]["websocket"]["tokenIssueSecret"])
' 2>&1)"
force_recreate
assert_eq "home marker survived" "home-marker" "$(exec_nanobot sh -c 'cat /data/home/marker-home' 2>&1)"
assert_eq "workspace marker survived" "workspace-marker" \
    "$(exec_nanobot sh -c 'cat /data/config/workspace/marker-workspace' 2>&1)"
token_after="$(exec_nanobot /app/.venv/bin/python -c '
import json
print(json.load(open("/data/config/config.json"))["channels"]["websocket"]["tokenIssueSecret"])
' 2>&1)"
assert_eq "WebUI token survived" "$token_before" "$token_after"
assert_contains "jq still runs after recreate" "$(exec_nanobot sh -c 'jq --version' 2>&1)" "jq-"
assert_contains "rg still runs after recreate" "$(exec_nanobot sh -c 'rg --version' 2>&1)" "ripgrep"

# ---------------------------------------------------------------------------
# Disposable cache wipe
# ---------------------------------------------------------------------------
section cache "Disposable cache wipe"
exec_root rm -rf /data/cache/pixi /data/cache/uv /data/cache/pip /data/cache/pycache
restart_service
for dir in /data/cache/pixi /data/cache/uv /data/cache/pip /data/cache/pycache; do
    assert_eq "$dir recreated and owned 1000:1000" "1000:1000" \
        "$(exec_nanobot_retry stat -c '%u:%g' "$dir" 2>/dev/null || echo missing)"
done
assert_contains "jq still works after cache wipe" "$(exec_nanobot sh -c 'jq --version' 2>&1)" "jq-"
assert_contains "rg still works after cache wipe" "$(exec_nanobot sh -c 'rg --version' 2>&1)" "ripgrep"
assert_eq "config still exists after cache wipe" "0" \
    "$(exec_nanobot test -f /data/config/config.json >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# Timezone
# ---------------------------------------------------------------------------
section timezone "Timezone (TZ)"
export TZ="Europe/Budapest"
force_recreate
tz_name="$(exec_nanobot date +%Z 2>&1)"
tz_offset="$(exec_nanobot date +%z 2>&1)"
case "$tz_name" in
    CET|CEST) pass "date +%Z is $tz_name" ;;
    *) fail "date +%Z is CET or CEST (got [$tz_name])" ;;
esac
case "$tz_offset" in
    +0100|+0200) pass "date +%z is $tz_offset" ;;
    *) fail "date +%z is +0100 or +0200 (got [$tz_offset])" ;;
esac

# ---------------------------------------------------------------------------
# Healthcheck and distinct host/container ports
# ---------------------------------------------------------------------------
section health "Healthcheck and port mapping"
assert_eq "Docker health is healthy" "healthy" "$(health_status)"
healthcheck_test="$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$CID")"
assert_contains "healthcheck uses -B" "$healthcheck_test" '"-B"'
assert_contains "healthcheck runs the stdlib script" "$healthcheck_test" "/usr/local/bin/healthcheck.py"
port_map="$(docker port "$CID" 18790 2>&1)"
assert_contains "container port 18790 is published on host $HEALTH_HOST_PORT" \
    "$port_map" "127.0.0.1:$HEALTH_HOST_PORT"

host_health=""
if command -v curl >/dev/null 2>&1; then
    host_health="$(curl -sS --max-time 5 -w '\nHTTP=%{http_code}' \
        "http://127.0.0.1:${HEALTH_HOST_PORT}/health" 2>&1 || true)"
fi
if [ -z "$host_health" ] && [ -x /mnt/c/Windows/System32/curl.exe ]; then
    host_health="$(/mnt/c/Windows/System32/curl.exe -sS --max-time 5 -w '\nHTTP=%{http_code}' \
        "http://127.0.0.1:${HEALTH_HOST_PORT}/health" 2>&1 || true)"
fi
assert_contains "host port $HEALTH_HOST_PORT/health returns 200" "$host_health" "HTTP=200"
assert_contains "host health payload reports ready" "$host_health" '"ready": true'

# ---------------------------------------------------------------------------
# Bootstrap with flags when config is missing
# ---------------------------------------------------------------------------
section bootstrap "Bootstrap with subcommand flags"
exec_root rm -f /data/config/config.json
"${COMPOSE[@]}" run -d --no-deps --name "$BOOTSTRAP_NAME" nanobot gateway --verbose >/dev/null \
    || fatal "compose run for bootstrap failed"
bootstrapped=""
for _ in $(seq 1 60); do
    if docker exec -u nanobot "$BOOTSTRAP_NAME" test -f /data/config/config.json >/dev/null 2>&1; then
        bootstrapped="yes"
        break
    fi
    sleep 1
done
assert_eq "gateway --verbose recreated config.json" "yes" "$bootstrapped"
bootstrap_logs="$(docker logs "$BOOTSTRAP_NAME" 2>&1 || true)"
assert_contains "bootstrap logged initialization" "$bootstrap_logs" "initialized /data/config/config.json"
assert_contains "bootstrap ran unprivileged" "$bootstrap_logs" "running as uid=1000"
bootstrap_workspace="$(docker exec -u nanobot "$BOOTSTRAP_NAME" /app/.venv/bin/python -c '
import json
print(json.load(open("/data/config/config.json"))["agents"]["defaults"]["workspace"])
' 2>&1)"
assert_eq "bootstrapped workspace is absolute" "/data/config/workspace" "$bootstrap_workspace"
docker rm -f "$BOOTSTRAP_NAME" >/dev/null 2>&1
restart_service

# ---------------------------------------------------------------------------
# Symlink safety and migration
# ---------------------------------------------------------------------------
section sym-safe "Symlink safety and migration"
for volume in "${PROJECT}_sym_config" "${PROJECT}_sym_home" "${PROJECT}_sym_pixi" "${PROJECT}_sym_cache"; do
    docker volume create "$volume" >/dev/null
done

docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v "${PROJECT}_sym_home:/data/home" \
    "$IMAGE" -c 'mkdir -p /data/home/.nanobot && echo legacy-data > /data/home/.nanobot/legacy.txt' \
    >/dev/null || fatal "could not seed legacy home"

docker run --rm --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true \
    -v "${PROJECT}_sym_config:/data/config" \
    -v "${PROJECT}_sym_home:/data/home" \
    -v "${PROJECT}_sym_pixi:/data/pixi" \
    -v "${PROJECT}_sym_cache:/data/cache" \
    "$IMAGE" /bin/true >/dev/null 2>&1
migration_rc=$?
assert_eq "migration startup exits 0" "0" "$migration_rc"

migration_state="$(docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v "${PROJECT}_sym_config:/data/config" \
    -v "${PROJECT}_sym_home:/data/home" \
    "$IMAGE" -c '
readlink -f /data/home/.nanobot
cat /data/config/legacy.txt
if [ -L /data/home/.nanobot ]; then echo source-replaced-by-symlink; else echo source-still-directory; fi
if compgen -G "/data/home/.nanobot.legacy.*" >/dev/null; then echo legacy-present; else echo no-legacy; fi
stat -c "%a %u:%g" /data/home/.nanobot
' 2>&1)"
migration_link="$(printf '%s\n' "$migration_state" | sed -n '1p')"
migration_data="$(printf '%s\n' "$migration_state" | sed -n '2p')"
migration_source="$(printf '%s\n' "$migration_state" | sed -n '3p')"
migration_legacy="$(printf '%s\n' "$migration_state" | sed -n '4p')"
migration_owner="$(printf '%s\n' "$migration_state" | sed -n '5p')"
assert_eq "migrated symlink resolves to /data/config" "/data/config" "$migration_link"
assert_eq "legacy file migrated without loss" "legacy-data" "$migration_data"
assert_eq "legacy source replaced by the symlink" "source-replaced-by-symlink" "$migration_source"
assert_eq "migration did not leave a legacy copy behind" "no-legacy" "$migration_legacy"
assert_eq "symlink ownership fixed" "777 1000:1000" "$migration_owner"

# Wrong-target symlink must fail closed and stay untouched.
docker volume create "${PROJECT}_sym_home2" >/dev/null
docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v "${PROJECT}_sym_home2:/data/home" \
    "$IMAGE" -c 'ln -s /data/elsewhere /data/home/.nanobot' >/dev/null
wrong_target_out="$(docker run --rm --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true \
    -v "${PROJECT}_sym_config:/data/config" \
    -v "${PROJECT}_sym_home2:/data/home" \
    -v "${PROJECT}_sym_pixi:/data/pixi" \
    -v "${PROJECT}_sym_cache:/data/cache" \
    "$IMAGE" /bin/true 2>&1)"
wrong_target_rc=$?
assert_nonzero_status "wrong-target symlink fails closed" "$wrong_target_rc"
assert_contains "failure explains the wrong target" "$wrong_target_out" "refusing to retarget symlink"
assert_eq "wrong-target symlink was not retargeted" "/data/elsewhere" \
    "$(docker run --rm --user 0:0 --entrypoint /bin/bash \
        -v "${PROJECT}_sym_home2:/data/home" "$IMAGE" \
        -c 'readlink /data/home/.nanobot' 2>&1)"

# Non-empty home .nanobot plus existing config data: preserve as legacy.
docker volume create "${PROJECT}_sym_home3" >/dev/null
docker volume create "${PROJECT}_sym_config3" >/dev/null
docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v "${PROJECT}_sym_home3:/data/home" -v "${PROJECT}_sym_config3:/data/config" \
    "$IMAGE" -c '
mkdir -p /data/home/.nanobot
echo old-home > /data/home/.nanobot/old.txt
echo "__keep__" > /data/config/config.json
' >/dev/null
docker run --rm --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true \
    -v "${PROJECT}_sym_config3:/data/config" \
    -v "${PROJECT}_sym_home3:/data/home" \
    -v "${PROJECT}_sym_pixi:/data/pixi" \
    -v "${PROJECT}_sym_cache:/data/cache" \
    "$IMAGE" /bin/true >/dev/null 2>&1
both_rc=$?
assert_eq "both-populated startup exits 0" "0" "$both_rc"
both_state="$(docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v "${PROJECT}_sym_home3:/data/home" -v "${PROJECT}_sym_config3:/data/config" \
    "$IMAGE" -c '
readlink -f /data/home/.nanobot
cat /data/config/config.json
cat /data/home/.nanobot.legacy.*/old.txt
' 2>&1)"
assert_eq "both-populated case still links to /data/config" "/data/config" \
    "$(printf '%s\n' "$both_state" | sed -n '1p')"
assert_eq "existing config was not overwritten" "__keep__" \
    "$(printf '%s\n' "$both_state" | sed -n '2p')"
assert_eq "non-empty home data preserved in legacy directory" "old-home" \
    "$(printf '%s\n' "$both_state" | sed -n '3p')"

# ---------------------------------------------------------------------------
# Update rejection, uv tools, and environment cheat sheet
# ---------------------------------------------------------------------------
section policy "Update rejection, uv tools, and cheat sheet"
update_out="$("${COMPOSE[@]}" run --rm --no-deps -T nanobot update 2>&1)"
update_rc=$?
assert_nonzero_status "nanobot update is rejected" "$update_rc"
assert_contains "rejection explains it is unsupported" "$update_out" "not supported"
assert_contains "rejection points at NANOBOT_VERSION" "$update_out" "NANOBOT_VERSION"

uv_out="$(exec_nanobot sh -c 'uv tool install ruff' 2>&1)"
assert_contains "uv tool install ruff succeeds" "$uv_out" "Installed"
assert_eq "uv tool directory is in /data/home" "0" \
    "$(exec_nanobot test -d /data/home/.local/share/uv/tools/ruff >/dev/null 2>&1; echo $?)"
assert_eq "uv cache was written under /data/cache/uv" "0" \
    "$(exec_nanobot sh -c 'find /data/cache/uv -mindepth 1 -print -quit | grep -q .' >/dev/null 2>&1; echo $?)"

assert_eq "/etc/nanobot-env.md is mode 0444" "444" \
    "$(exec_root stat -c '%a' /etc/nanobot-env.md)"
cheat_sheet="$(exec_root cat /etc/nanobot-env.md 2>&1)"
assert_contains "cheat sheet documents pixi global install" "$cheat_sheet" "pixi global install"
assert_contains "cheat sheet forbids sudo" "$cheat_sheet" "sudo"
assert_contains "cheat sheet forbids apt" "$cheat_sheet" "apt"
assert_contains "cheat sheet documents disposable cache" "$cheat_sheet" "disposable"
assert_contains "cheat sheet documents NANOBOT_CHANNELS" "$cheat_sheet" "NANOBOT_CHANNELS"

# ---------------------------------------------------------------------------
# Channel dependencies from NANOBOT_CHANNELS
# ---------------------------------------------------------------------------
section channels "Channel dependencies (NANOBOT_CHANNELS)"
assert_eq "/usr/local/bin/nanobot-channels.py is executable" "0" \
    "$(exec_nanobot test -x /usr/local/bin/nanobot-channels.py >/dev/null 2>&1; echo $?)"
assert_eq "the image exposes NANOBOT_VERSION" "$EXPECTED_NANOBOT_VERSION" \
    "$(docker run --rm --entrypoint sh "$IMAGE" -c 'echo "$NANOBOT_VERSION"' 2>&1)"
absent_out="$(docker run --rm --entrypoint /app/.venv/bin/python "$IMAGE" \
    -c 'import discord' 2>&1)"
absent_rc=$?
assert_nonzero_status "discord is absent from the image venv until installed" "$absent_rc"
assert_contains "the absent import fails cleanly" "$absent_out" "ModuleNotFoundError"

cache_before="$(exec_nanobot du -sk /data/cache/uv | cut -f1)"

export NANOBOT_CHANNELS="discord,telegram,slack"
recreate_start=$SECONDS
force_recreate
recreate_seconds=$((SECONDS - recreate_start))
assert_eq "compose passes NANOBOT_CHANNELS to the container" "discord,telegram,slack" \
    "$(exec_nanobot_retry printenv NANOBOT_CHANNELS || true)"

channel_logs="$(docker logs "$CID" 2>&1 || true)"
assert_contains "startup logs the channel dependency install" "$channel_logs" \
    "installing channel dependencies for: discord, telegram, slack"
assert_contains "startup confirms the channel dependency install" "$channel_logs" \
    "installed channel dependencies for: discord, telegram, slack"

channel_imports="$(exec_nanobot_retry /app/.venv/bin/python -c \
    'import discord, telegram, slack_sdk; print("imports-ok")' 2>&1)"
assert_eq "discord, telegram, and slack_sdk import from /app/.venv" "imports-ok" \
    "$channel_imports"
channel_versions="$(exec_nanobot /app/.venv/bin/python -c '
from importlib.metadata import version
from packaging.requirements import Requirement
checks = (
    ("discord.py", "discord.py>=2.5.2,<3.0.0"),
    ("python-telegram-bot", "python-telegram-bot[socks,webhooks]>=22.6,<23.0"),
    ("slack-sdk", "slack-sdk>=3.39.0,<4.0.0"),
)
for name, spec in checks:
    installed = version(name)
    if not Requirement(spec).specifier.contains(installed):
        raise SystemExit(f"{name} {installed} does not satisfy {spec}")
    print(f"{name}={installed}")
' 2>&1)"
assert_contains "discord.py satisfies the manifest constraint" "$channel_versions" "discord.py=2."
assert_contains "python-telegram-bot satisfies the manifest constraint" \
    "$channel_versions" "python-telegram-bot=22."
assert_contains "slack-sdk satisfies the manifest constraint" "$channel_versions" "slack-sdk=3."

gateway_channels_env="$(exec_root sh -c '
for p in /proc/[0-9]*; do
    if [ "$(cat "$p/comm" 2>/dev/null)" = "nanobot-gateway" ]; then
        if tr "\0" "\n" < "$p/environ" | grep -q "^NANOBOT_CHANNELS="; then
            echo present
        else
            echo absent
        fi
        break
    fi
done
' 2>/dev/null)"
assert_eq "the gateway does not inherit NANOBOT_CHANNELS" "absent" "$gateway_channels_env"
assert_contains "nanobot status still works while NANOBOT_CHANNELS is set" \
    "$(exec_nanobot_retry sh -c 'nanobot status' 2>&1 || true)" "/data/config/config.json"

cache_after="$(exec_nanobot du -sk /data/cache/uv | cut -f1)"
if [ "$cache_after" -gt "$cache_before" ]; then
    pass "channel wheels were written to /data/cache/uv (+$((cache_after - cache_before)) KB)"
else
    fail "channel wheels were written to /data/cache/uv (before ${cache_before} KB, after ${cache_after} KB)"
fi
printf 'recreate to healthy with installs: %ss, cache: %s\n' \
    "$recreate_seconds" "$(exec_root du -sh /data/cache/uv 2>&1)"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
restart_start=$SECONDS
restart_service
restart_seconds=$((SECONDS - restart_start))
restart_logs="$(docker logs --since "$since" "$CID" 2>&1 || true)"
for name in discord telegram slack; do
    assert_contains "channel '$name' dependencies already installed on restart" \
        "$restart_logs" "channel dependencies for '$name' already installed"
done
if printf '%s' "$restart_logs" | grep -Fq "installing channel dependencies"; then
    fail "restart did not run uv again"
else
    pass "restart did not run uv again"
fi
printf 'restart to healthy without reinstalling: %ss\n' "$restart_seconds"

offline_start=$SECONDS
offline_out="$("${COMPOSE[@]}" run --rm --no-deps -T -e UV_OFFLINE=1 nanobot /bin/true 2>&1)"
offline_rc=$?
offline_seconds=$((SECONDS - offline_start))
assert_eq "a fresh container replays the install with UV_OFFLINE=1" "0" "$offline_rc"
assert_contains "the offline replay installed from the cache" "$offline_out" \
    "installed channel dependencies for: discord, telegram, slack"
assert_contains "the offline replay reports the uv result" "$offline_out" "uv:"
printf 'offline replay in a fresh container: %ss\n' "$offline_seconds"

export NANOBOT_CHANNELS="not-a-real-channel"
force_recreate
unknown_logs="$(docker logs "$CID" 2>&1 || true)"
assert_contains "unknown channel name logs a warning" "$unknown_logs" \
    "WARNING: unknown channel(s) in NANOBOT_CHANNELS: not-a-real-channel"
assert_contains "unknown channel warning names the known channels" "$unknown_logs" \
    "known channels:"
assert_contains "unknown channel warning points at nanobot channels" "$unknown_logs" \
    "nanobot channels"
assert_eq "container is healthy despite the unknown channel" "healthy" "$(health_status)"
assert_contains "gateway still runs after the unknown channel" \
    "$(docker top "$CID" -o pid,args 2>/dev/null || true)" "nanobot-gateway"
export NANOBOT_CHANNELS=""

# ---------------------------------------------------------------------------
# Homebrew on its own volume, npm global prefix, and workspace AGENTS.md rules
#
# Both install paths are exercised through the env nanobot's WebUI app runner
# actually passes (nanobot/apps/cli/service.py:_subprocess_env -> HOME, LANG,
# TERM, PATH, PYTHONUNBUFFERED), not through the image env: that is the path
# that has to work, and it is the one where HOMEBREW_*/npm_config_* are absent.
#
# The formula defaults to `tree` because it is one small bottle. `jq` needs
# linux-headers/glibc/gcc/binutils (~1.1 GB of bottles) on this Homebrew; use
# NANOBOT_SMOKE_BREW_FORMULA=jq to run that heavier path deliberately.
# ---------------------------------------------------------------------------
section apps "Homebrew, npm prefix, and workspace AGENTS.md rules"
ALLOWLIST_ENV="env -i HOME=/data/home LANG=C.UTF-8 TERM=dumb PATH=/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin PYTHONUNBUFFERED=1"
BREW_FORMULA="${NANOBOT_SMOKE_BREW_FORMULA:-tree}"

mounts="$(docker inspect -f '{{range .Mounts}}{{.Type}} {{.Destination}};{{end}}' "$CID")"
assert_contains "brew is a named volume at /data/brew" "$mounts" "volume /data/brew;"
assert_eq "the brew wrapper is first on PATH" "/data/home/.local/bin/brew" \
    "$(exec_nanobot sh -c 'command -v brew')"
assert_eq "the wrapper resolves to the image's brew entry point" \
    "/usr/local/bin/nanobot-brew" "$(exec_nanobot readlink -f /data/home/.local/bin/brew)"
assert_eq "brew --prefix is /data/brew" "/data/brew" \
    "$(exec_nanobot sh -c 'brew --prefix')"
assert_contains "brew --version reports pinned Homebrew ${BREW_VERSION:-$EXPECTED_BREW_VERSION}" \
    "$(exec_nanobot sh -c 'brew --version' 2>&1)" "Homebrew ${BREW_VERSION:-$EXPECTED_BREW_VERSION}"

run_detached "brew install $BREW_FORMULA (app-runner env)" \
    "cd /data/home; $ALLOWLIST_ENV /bin/bash -c 'brew install $BREW_FORMULA'" 300
assert_eq "brew install $BREW_FORMULA succeeds with the app-runner env" "0" "$DETACHED_RC"
assert_contains "the bottle install reports success" \
    "$(exec_nanobot sh -c 'cat /tmp/smoke-cmd.log' 2>&1)" "$BREW_FORMULA"
assert_eq "the wrapper suppresses brew's auto-update git fetch" "0" \
    "$(exec_nanobot sh -c "grep -c 'Auto-updating Homebrew' /tmp/smoke-cmd.log || true" 2>/dev/null)"

brew_which="$(exec_nanobot sh -c "$ALLOWLIST_ENV /app/.venv/bin/python -c 'import shutil, sys; print(str(shutil.which(sys.argv[1])))' $BREW_FORMULA" 2>&1)"
assert_eq "shutil.which finds the bottle binary without HOMEBREW_* vars" \
    "/data/brew/bin/$BREW_FORMULA" "$brew_which"
assert_contains "the bottle binary runs" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV $BREW_FORMULA --version" 2>&1)" "$BREW_FORMULA"

assert_eq "npm prefix is recorded in ~/.npmrc" "prefix=/data/home/.local" \
    "$(exec_nanobot sh -c "grep -x 'prefix=/data/home/.local' /data/home/.npmrc" 2>/dev/null)"
run_detached "npm install -g cowsay@1.5.0 (app-runner env)" \
    "cd /data/home; $ALLOWLIST_ENV /bin/bash -c 'npm install -g cowsay@1.5.0'" 180
assert_eq "npm install -g succeeds with the app-runner env" "0" "$DETACHED_RC"
assert_eq "npm global bins land in ~/.local/bin" "/data/home/.local/bin/cowsay" \
    "$(exec_nanobot sh -c 'command -v cowsay')"
assert_contains "the npm-installed CLI runs" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV cowsay -t smoke" 2>&1)" "< smoke >"

# The entrypoint seeds the workspace from nanobot's templates and adds one
# marked rules block before the gateway starts.
assert_eq "the workspace AGENTS.md carries exactly one rules block" "1" \
    "$(exec_nanobot sh -c 'grep -c nanobot-image-env:begin /data/config/workspace/AGENTS.md')"
exec_nanobot sh -c '/app/.venv/bin/python -B /usr/local/bin/workspace-agents-env.py --seed-templates /data/config/workspace' >/dev/null 2>&1
exec_nanobot sh -c '/app/.venv/bin/python -B /usr/local/bin/workspace-agents-env.py --seed-templates /data/config/workspace' >/dev/null 2>&1
assert_eq "re-running the rules helper does not duplicate the block" "1" \
    "$(exec_nanobot sh -c 'grep -c nanobot-image-env:begin /data/config/workspace/AGENTS.md')"
assert_eq "the block is closed exactly once" "1" \
    "$(exec_nanobot sh -c 'grep -c nanobot-image-env:end /data/config/workspace/AGENTS.md')"
assert_contains "the block states the no-apt/no-sudo rule" \
    "$(exec_nanobot sh -c 'cat /data/config/workspace/AGENTS.md')" 'no `apt`/`apt-get`/`apk`'
assert_contains "the block reserves brew for WebUI Apps" \
    "$(exec_nanobot sh -c 'cat /data/config/workspace/AGENTS.md')" 'Do not use `brew` for ad-hoc tool installs'

force_recreate
assert_eq "brew still resolves after a recreate" "/data/home/.local/bin/brew" \
    "$(exec_nanobot_retry sh -c 'command -v brew')"
assert_eq "the brew wrapper is still linked after the recreate" \
    "/usr/local/bin/nanobot-brew" \
    "$(exec_nanobot_retry readlink -f /data/home/.local/bin/brew)"
assert_eq "the brew bottle survives the recreate" "/data/brew/bin/$BREW_FORMULA" \
    "$(exec_nanobot_retry sh -c "$ALLOWLIST_ENV /app/.venv/bin/python -c 'import shutil, sys; print(shutil.which(sys.argv[1]) or \"\")' $BREW_FORMULA" 2>&1)"
assert_contains "the brew bottle still runs after the recreate" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV $BREW_FORMULA --version" 2>&1)" "$BREW_FORMULA"
assert_eq "npm prefix survives the recreate" "/data/home/.local" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV npm prefix -g" 2>&1)"
assert_contains "the npm-installed CLI still runs after the recreate" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV cowsay -t again" 2>&1)" "< again >"

# Single empty /data mount (mirrors ./data:/data): entrypoint must create all
# five trees, own them as 1000:1000, and seed Homebrew without network.
docker volume create "${PROJECT}_single_data" >/dev/null
single_out="$(docker run --rm --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID \
    --security-opt no-new-privileges:true \
    -v "${PROJECT}_single_data:/data" \
    "$IMAGE" /bin/bash -c '
for d in /data/config /data/home /data/pixi /data/brew /data/cache; do
    test -d "$d" || exit 1
done
brew --version
' 2>&1)"
single_rc=$?
assert_eq "single empty /data mount initializes all five trees and seeds Homebrew" "0" "$single_rc"
assert_contains "seeded Homebrew reports pinned version on single /data mount" \
    "$single_out" "Homebrew ${BREW_VERSION:-$EXPECTED_BREW_VERSION}"

# ---------------------------------------------------------------------------
printf '\n=== Summary ===\n'
printf 'passed checks: %d\n' "$PASSED"
printf 'failed checks: %d\n' "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
printf 'ALL SMOKE TESTS PASSED\n'

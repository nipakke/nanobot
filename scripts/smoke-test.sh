#!/usr/bin/env bash
# Acceptance suite for the nanobot + pixi image (A1-A22).
#
# Builds nanobot-pixi:smoke, runs it through Compose with five fresh, initially
# root-owned named volumes, and exercises entrypoint, persistence, pixi, health,
# bootstrap, symlink safety, upgrade rejection, channel dependency installs,
# Homebrew on its own volume, and the npm global prefix.
# Uses a unique Compose project name and removes only the resources it creates.
set -uo pipefail

cd "$(dirname "$0")/.."

readonly IMAGE="nanobot-pixi:smoke"
readonly PROJECT="nanobot-smoke-$$"
# compose.yaml pins `container_name: nanobot` for operators. The suite passes
# scripts/smoke-compose.yaml last to override it, so an operator's `nanobot`
# container is never taken over (or removed by `down --remove-orphans`).
readonly CONTAINER_NAME="${PROJECT}-nanobot"
readonly BOOTSTRAP_NAME="${PROJECT}-bootstrap"
readonly BUILD_LOG="${TMPDIR:-/tmp}/nanobot-smoke-build.log"

export NANOBOT_SMOKE_CONTAINER="$CONTAINER_NAME"
COMPOSE=(docker compose -p "$PROJECT" \
    -f compose.yaml \
    -f compose.build.yaml \
    -f scripts/smoke-compose.yaml)
CID=""
PASSED=0
FAILED=0

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
)

pass() { printf 'A%-2s PASS  %s\n' "$1" "$2"; PASSED=$((PASSED + 1)); }
fail() {
    printf 'A%-2s FAIL  %s\n' "$1" "$2" >&2
    FAILED=$((FAILED + 1))
}
fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

assert_eq() {
    local num="$1" desc="$2" expected="$3" actual="$4"
    if [ "$expected" = "$actual" ]; then
        pass "$num" "$desc"
    else
        fail "$num" "$desc (expected [$expected], got [$actual])"
    fi
}

assert_contains() {
    local num="$1" desc="$2" haystack="$3" needle="$4"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        pass "$num" "$desc"
    else
        fail "$num" "$desc (missing [$needle])"
    fi
}

assert_nonzero_status() {
    local num="$1" desc="$2" rc="$3"
    if [ "$rc" -ne 0 ]; then
        pass "$num" "$desc"
    else
        fail "$num" "$desc (expected nonzero exit, got 0)"
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
# Homebrew and npm installs produce no output until they finish, and this host
# has already returned HTTP 500 from a long `docker exec` stream while the
# container kept running. Detaching keeps the work alive, keeps the suite's
# output moving (a dot per poll), and makes a broken CLI stream harmless.
# Sets DETACHED_RC (empty on timeout) and DETACHED_SECONDS.
DETACHED_RC=""
DETACHED_SECONDS=0
run_detached() {
    local label="$1" command="$2" limit="$3" waited=0 rc=""

    exec_nanobot rm -f /tmp/smoke-cmd.rc /tmp/smoke-cmd.log >/dev/null 2>&1
    docker exec -d -u nanobot "$CID" sh -c \
        "$command >/tmp/smoke-cmd.log 2>&1; echo \$? >/tmp/smoke-cmd.rc" >/dev/null 2>&1
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
# A1: build
# ---------------------------------------------------------------------------
printf '\n=== A1: build ===\n'
if docker build -t "$IMAGE" . >"$BUILD_LOG" 2>&1; then
    pass 1 "docker build -t $IMAGE ."
    tail -5 "$BUILD_LOG"
else
    fail 1 "docker build -t $IMAGE ."
    tail -40 "$BUILD_LOG" >&2
    exit 1
fi

image_user="$(docker image inspect -f '{{.Config.User}}' "$IMAGE")"
assert_eq 6 "image user is root for the setup phase" "root" "$image_user"
entrypoint_json="$(docker image inspect -f '{{json .Config.Entrypoint}}' "$IMAGE")"
assert_contains 7 "image entrypoint wraps the script with tini" "$entrypoint_json" '"/usr/bin/tini"'
assert_contains 7 "image entrypoint runs entrypoint.sh" "$entrypoint_json" '"/usr/local/bin/entrypoint.sh"'

# ---------------------------------------------------------------------------
# A6: pre-create the four volumes root-owned, then start with exact caps.
# ---------------------------------------------------------------------------
printf '\n=== A6: fresh root-owned volumes, exact capabilities ===\n'
for volume in "${VOLUMES[@]}"; do
    docker volume create "$volume" >/dev/null || fatal "could not create $volume"
done

export NANOBOT_IMAGE="$IMAGE"
export EXTRA_PIXI_PACKAGES="jq,ripgrep,nodejs"
export TZ="UTC"
export NANOBOT_HEALTH_HOST_PORT="18791"
export NANOBOT_HEALTH_PORT="18790"
export NANOBOT_WEB_TOKEN="smoke-web-token"
# Host ports are distinct from the operator defaults (8765, 18790) so the suite
# can run next to a live stack; the container-side ports stay 8765 and 18790.
export NANOBOT_WEB_PORT="18766"

if "${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 300; then
    pass 6 "startup fixes ownership on fresh root-owned volumes and becomes healthy"
else
    fail 6 "startup on fresh root-owned volumes"
    "${COMPOSE[@]}" logs --no-color --tail 100 nanobot >&2 || true
    exit 1
fi
CID="$("${COMPOSE[@]}" ps -q nanobot)"
[ -n "$CID" ] || fatal "compose did not report a container id"

cap_drop="$(docker inspect -f '{{json .HostConfig.CapDrop}}' "$CID")"
cap_add="$(docker inspect -f '{{json .HostConfig.CapAdd}}' "$CID")"
security_opt="$(docker inspect -f '{{json .HostConfig.SecurityOpt}}' "$CID")"
assert_eq 6 "cap_drop is exactly ALL" '["ALL"]' "$cap_drop"
for cap in CHOWN DAC_OVERRIDE SETUID SETGID; do
    if printf '%s' "$cap_add" | grep -Eq "\"(CAP_)?${cap}\""; then
        pass 6 "cap_add includes $cap"
    else
        fail 6 "cap_add includes $cap (got $cap_add)"
    fi
done
cap_count="$(printf '%s' "$cap_add" | grep -o '"' | wc -l)"
assert_eq 6 "cap_add has exactly four entries" "8" "$cap_count"
assert_contains 6 "no-new-privileges is enabled" "$security_opt" 'no-new-privileges:true'
entrypoint_body="$(exec_root cat /usr/local/bin/entrypoint.sh)"
assert_contains 6 "entrypoint uses the mismatched-owner find scan" "$entrypoint_body" \
    '! -uid "$NANOBOT_UID"'
if printf '%s' "$entrypoint_body" | grep -Fq "chown -R"; then
    fail 6 "entrypoint does not run an unconditional recursive chown"
else
    pass 6 "entrypoint does not run an unconditional recursive chown"
fi

# ---------------------------------------------------------------------------
# A2: unprivileged identity
# ---------------------------------------------------------------------------
printf '\n=== A2: identity ===\n'
assert_eq 2 "id -u is 1000" "1000" "$(exec_nanobot id -u)"
assert_eq 2 "id -g is 1000" "1000" "$(exec_nanobot id -g)"
assert_eq 2 "command -v sudo is empty" "" "$(exec_nanobot sh -c 'command -v sudo || true')"

# ---------------------------------------------------------------------------
# A3: environment
# ---------------------------------------------------------------------------
printf '\n=== A3: environment ===\n'
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
    PIXI_NO_TELEMETRY=1; do
    var="${pair%%=*}"
    expected="${pair#*=}"
    assert_eq 3 "$var is $expected" "$expected" "$(exec_nanobot printenv "$var" || true)"
done
path_value="$(exec_nanobot printenv PATH || true)"
case "$path_value" in
    /data/pixi/bin:/data/home/.local/bin:/app/.venv/bin:*) pass 3 "PATH starts with pixi, home bin, venv" ;;
    *) fail 3 "PATH starts with pixi, home bin, venv (got [$path_value])" ;;
esac

# ---------------------------------------------------------------------------
# A4: tool versions
# ---------------------------------------------------------------------------
printf '\n=== A4: versions ===\n'
nanobot_version="$(exec_nanobot sh -c 'nanobot --version' 2>&1)"
pixi_version="$(exec_nanobot sh -c 'pixi --version' 2>&1)"
uv_version="$(exec_nanobot sh -c 'uv --version' 2>&1)"
tini_version="$(exec_nanobot sh -c 'tini --version' 2>&1)"
assert_contains 4 "nanobot --version" "$nanobot_version" "0.4.2"
assert_contains 4 "pixi --version" "$pixi_version" "0.84.2"
assert_contains 4 "uv --version" "$uv_version" "uv "
assert_contains 4 "tini --version" "$tini_version" "tini version"

# ---------------------------------------------------------------------------
# A5: persistent trees, venv, no bwrap
# ---------------------------------------------------------------------------
printf '\n=== A5: filesystem ===\n'
for dir in /data/config /data/home /data/pixi /data/cache \
    /data/cache/pixi /data/cache/uv /data/cache/pip /data/config/workspace \
    /data/home/.local/bin /data/home/.local/share/uv/tools; do
    owner="$(exec_root stat -c '%u:%g' "$dir" 2>/dev/null || echo missing)"
    assert_eq 5 "$dir exists and is owned 1000:1000 after startup" "1000:1000" "$owner"
done
image_tree_owners="$(docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
for d in /data/home/.local/bin /data/home/.local/share/uv/tools; do
    stat -c "%n %u:%g" "$d"
done
' 2>&1)"
assert_contains 5 "/data/home/.local/bin is 1000:1000 in the built image" \
    "$image_tree_owners" "/data/home/.local/bin 1000:1000"
assert_contains 5 "/data/home/.local/share/uv/tools is 1000:1000 in the built image" \
    "$image_tree_owners" "/data/home/.local/share/uv/tools 1000:1000"
assert_eq 5 "/app/.venv is writable by nanobot" "0" \
    "$(exec_nanobot sh -c 'test -w /app/.venv' >/dev/null 2>&1; echo $?)"
assert_eq 5 "bwrap is absent" "" "$(exec_nanobot sh -c 'command -v bwrap || true')"
mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$CID")"
assert_contains 5 "config volume mounted at /data/config" "$mounts" "/data/config"
assert_contains 5 "home volume mounted at /data/home" "$mounts" "/data/home"
assert_contains 5 "pixi volume mounted at /data/pixi" "$mounts" "/data/pixi"
assert_contains 5 "cache volume mounted at /data/cache" "$mounts" "/data/cache"
case " $mounts " in
    *" /app "*) fail 5 "/app is not mounted over" ;;
    *) pass 5 "/app (including .venv) is not mounted over" ;;
esac

# ---------------------------------------------------------------------------
# A7: PID 1 and gateway user
# ---------------------------------------------------------------------------
printf '\n=== A7: PID 1 and process user ===\n'
assert_eq 7 "PID 1 is tini" "tini" "$(exec_root cat /proc/1/comm 2>/dev/null || echo missing)"
gateway_status="$(exec_root sh -c '
for p in /proc/[0-9]*; do
    if [ "$(cat "$p/comm" 2>/dev/null)" = "nanobot-gateway" ]; then
        echo "found"
        grep -E "^(Uid|CapEff):" "$p/status"
        break
    fi
done
' 2>/dev/null)"
assert_contains 7 "gateway process is nanobot-gateway" "$gateway_status" "found"
assert_contains 7 "gateway process uid is 1000" "$gateway_status" $'Uid:\t1000'
assert_contains 7 "gateway process has no effective capabilities" "$gateway_status" \
    $'CapEff:\t0000000000000000'
assert_contains 7 "uid 1000 resolves to nanobot" \
    "$(exec_root getent passwd 1000 2>/dev/null || true)" "nanobot"
top_output="$(docker top "$CID" -o pid,user,args 2>/dev/null || true)"
assert_contains 7 "docker top shows the gateway as nanobot/1000" "$top_output" "nanobot-gateway"
printf '%s\n' "$top_output" | sed -n '1,5p'

# ---------------------------------------------------------------------------
# A8: symlink
# ---------------------------------------------------------------------------
printf '\n=== A8: symlink ===\n'
assert_eq 8 "/data/home/.nanobot resolves to /data/config" "/data/config" \
    "$(exec_nanobot readlink -f /data/home/.nanobot)"
assert_eq 8 "the symlink is owned by 1000:1000" "1000:1000" \
    "$(exec_root stat -c '%u:%g' /data/home/.nanobot)"

# ---------------------------------------------------------------------------
# A9: nanobot status names the real config path
# ---------------------------------------------------------------------------
printf '\n=== A9: status ===\n'
status_output="$(exec_nanobot sh -c 'nanobot status' 2>&1 || true)"
assert_contains 9 "nanobot status names /data/config/config.json" \
    "$status_output" "/data/config/config.json"

# ---------------------------------------------------------------------------
# A10: generated config
# ---------------------------------------------------------------------------
printf '\n=== A10: config ===\n'
config_fields="$(exec_nanobot /app/.venv/bin/python -c '
import json
c = json.load(open("/data/config/config.json"))
print(c["agents"]["defaults"]["workspace"])
print(c["gateway"]["host"])
w = c["channels"]["websocket"]
print(w["host"])
print(w["port"])
' 2>&1)"
workspace_line="$(printf '%s\n' "$config_fields" | sed -n '1p')"
gateway_host_line="$(printf '%s\n' "$config_fields" | sed -n '2p')"
ws_host_line="$(printf '%s\n' "$config_fields" | sed -n '3p')"
ws_port_line="$(printf '%s\n' "$config_fields" | sed -n '4p')"
assert_eq 10 "agents.defaults.workspace is /data/config/workspace" \
    "/data/config/workspace" "$workspace_line"
assert_eq 10 "gateway.host is 0.0.0.0" "0.0.0.0" "$gateway_host_line"
assert_eq 10 "websocket host is 0.0.0.0" "0.0.0.0" "$ws_host_line"
assert_eq 10 "websocket port is 8765" "8765" "$ws_port_line"

# ---------------------------------------------------------------------------
# A11: pixi extras in separate environments
# ---------------------------------------------------------------------------
printf '\n=== A11: pixi extras ===\n'
assert_contains 11 "jq --version works" \
    "$(exec_nanobot sh -c 'jq --version' 2>&1)" "jq-"
rg_version="$(exec_nanobot sh -c 'rg --version' 2>&1)"
assert_contains 11 "rg --version works" "$rg_version" "ripgrep"
assert_eq 11 "/data/pixi/envs/jq exists" "0" \
    "$(exec_nanobot test -d /data/pixi/envs/jq >/dev/null 2>&1; echo $?)"
assert_eq 11 "/data/pixi/envs/ripgrep exists" "0" \
    "$(exec_nanobot test -d /data/pixi/envs/ripgrep >/dev/null 2>&1; echo $?)"
assert_eq 11 "no shared /data/pixi/envs/extra environment" "1" \
    "$(exec_nanobot test -e /data/pixi/envs/extra >/dev/null 2>&1; echo $?)"
pixi_list="$(exec_nanobot sh -c 'pixi global list' 2>&1)"
assert_contains 11 "pixi global list shows jq" "$pixi_list" "jq"
assert_contains 11 "pixi global list shows ripgrep" "$pixi_list" "ripgrep"

# ---------------------------------------------------------------------------
# A12: idempotent extras on restart
# ---------------------------------------------------------------------------
printf '\n=== A12: extras are not reinstalled ===\n'
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
restart_service
restart_logs="$(docker logs --since "$since" "$CID" 2>&1 || true)"
assert_contains 12 "jq already present on restart" "$restart_logs" "pixi package 'jq' already present"
assert_contains 12 "ripgrep already present on restart" "$restart_logs" "pixi package 'ripgrep' already present"
if printf '%s' "$restart_logs" | grep -Fq "installing pixi package"; then
    fail 12 "no pixi install on restart"
else
    pass 12 "no pixi install on restart"
fi

# ---------------------------------------------------------------------------
# A13: restricted .ssh directory survives restart and recreate
# ---------------------------------------------------------------------------
printf '\n=== A13: 0700 .ssh ===\n'
exec_root mkdir -p /data/home/.ssh
exec_root chmod 700 /data/home/.ssh
exec_root chown 1000:1000 /data/home/.ssh
assert_eq 13 ".ssh starts at 700 1000:1000" "700 1000:1000" \
    "$(exec_root stat -c '%a %u:%g' /data/home/.ssh)"
restart_service
assert_eq 13 "restart succeeds and keeps .ssh at 700 1000:1000" "700 1000:1000" \
    "$(exec_nanobot_retry stat -c '%a %u:%g' /data/home/.ssh)"
force_recreate
assert_eq 13 "force-recreate succeeds and keeps .ssh at 700 1000:1000" "700 1000:1000" \
    "$(exec_nanobot_retry stat -c '%a %u:%g' /data/home/.ssh)"
startup_logs="$(docker logs "$CID" 2>&1 | grep -iE 'permission denied|operation not permitted' || true)"
assert_eq 13 "ownership scan did not hit permission errors" "" "$startup_logs"

# ---------------------------------------------------------------------------
# A14: persistence across force-recreate
# ---------------------------------------------------------------------------
printf '\n=== A14: force-recreate persistence ===\n'
exec_nanobot sh -c 'echo home-marker > /data/home/marker-home'
exec_nanobot sh -c 'echo workspace-marker > /data/config/workspace/marker-workspace'
token_before="$(exec_nanobot /app/.venv/bin/python -c '
import json
print(json.load(open("/data/config/config.json"))["channels"]["websocket"]["tokenIssueSecret"])
' 2>&1)"
force_recreate
assert_eq 14 "home marker survived" "home-marker" "$(exec_nanobot sh -c 'cat /data/home/marker-home' 2>&1)"
assert_eq 14 "workspace marker survived" "workspace-marker" \
    "$(exec_nanobot sh -c 'cat /data/config/workspace/marker-workspace' 2>&1)"
token_after="$(exec_nanobot /app/.venv/bin/python -c '
import json
print(json.load(open("/data/config/config.json"))["channels"]["websocket"]["tokenIssueSecret"])
' 2>&1)"
assert_eq 14 "WebUI token survived" "$token_before" "$token_after"
assert_contains 14 "jq still runs after recreate" "$(exec_nanobot sh -c 'jq --version' 2>&1)" "jq-"
assert_contains 14 "rg still runs after recreate" "$(exec_nanobot sh -c 'rg --version' 2>&1)" "ripgrep"

# ---------------------------------------------------------------------------
# A15: cache disposal
# ---------------------------------------------------------------------------
printf '\n=== A15: cache wipe ===\n'
exec_root rm -rf /data/cache/pixi /data/cache/uv /data/cache/pip
restart_service
for dir in /data/cache/pixi /data/cache/uv /data/cache/pip; do
    assert_eq 15 "$dir recreated and owned 1000:1000" "1000:1000" \
        "$(exec_nanobot_retry stat -c '%u:%g' "$dir" 2>/dev/null || echo missing)"
done
assert_contains 15 "jq still works after cache wipe" "$(exec_nanobot sh -c 'jq --version' 2>&1)" "jq-"
assert_contains 15 "rg still works after cache wipe" "$(exec_nanobot sh -c 'rg --version' 2>&1)" "ripgrep"
assert_eq 15 "config still exists after cache wipe" "0" \
    "$(exec_nanobot test -f /data/config/config.json >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# A16: TZ
# ---------------------------------------------------------------------------
printf '\n=== A16: timezone ===\n'
export TZ="Europe/Budapest"
force_recreate
tz_name="$(exec_nanobot date +%Z 2>&1)"
tz_offset="$(exec_nanobot date +%z 2>&1)"
case "$tz_name" in
    CET|CEST) pass 16 "date +%Z is $tz_name" ;;
    *) fail 16 "date +%Z is CET or CEST (got [$tz_name])" ;;
esac
case "$tz_offset" in
    +0100|+0200) pass 16 "date +%z is $tz_offset" ;;
    *) fail 16 "date +%z is +0100 or +0200 (got [$tz_offset])" ;;
esac

# ---------------------------------------------------------------------------
# A17: health and distinct host/container ports
# ---------------------------------------------------------------------------
printf '\n=== A17: health ===\n'
assert_eq 17 "Docker health is healthy" "healthy" "$(health_status)"
healthcheck_test="$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$CID")"
assert_contains 17 "healthcheck uses -B" "$healthcheck_test" '"-B"'
assert_contains 17 "healthcheck runs the stdlib script" "$healthcheck_test" "/usr/local/bin/healthcheck.py"
port_map="$(docker port "$CID" 18790 2>&1)"
assert_contains 17 "container port 18790 is published on host 18791" "$port_map" "127.0.0.1:18791"
assert_eq 17 "container NANOBOT_HEALTH_PORT is 18790" "18790" \
    "$(exec_root printenv NANOBOT_HEALTH_PORT || true)"

host_health=""
if command -v curl >/dev/null 2>&1; then
    host_health="$(curl -sS --max-time 5 -w '\nHTTP=%{http_code}' \
        http://127.0.0.1:18791/health 2>&1 || true)"
fi
if [ -z "$host_health" ] && [ -x /mnt/c/Windows/System32/curl.exe ]; then
    host_health="$(/mnt/c/Windows/System32/curl.exe -sS --max-time 5 -w '\nHTTP=%{http_code}' \
        http://127.0.0.1:18791/health 2>&1 || true)"
fi
assert_contains 17 "host port 18791/health returns 200" "$host_health" "HTTP=200"
assert_contains 17 "host health payload reports ready" "$host_health" '"ready": true'

# ---------------------------------------------------------------------------
# A18: bootstrap with flags when config is missing
# ---------------------------------------------------------------------------
printf '\n=== A18: bootstrap with flags ===\n'
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
assert_eq 18 "gateway --verbose recreated config.json" "yes" "$bootstrapped"
bootstrap_logs="$(docker logs "$BOOTSTRAP_NAME" 2>&1 || true)"
assert_contains 18 "bootstrap logged initialization" "$bootstrap_logs" "initialized /data/config/config.json"
assert_contains 18 "bootstrap ran unprivileged" "$bootstrap_logs" "running as uid=1000"
bootstrap_workspace="$(docker exec -u nanobot "$BOOTSTRAP_NAME" /app/.venv/bin/python -c '
import json
print(json.load(open("/data/config/config.json"))["agents"]["defaults"]["workspace"])
' 2>&1)"
assert_eq 18 "bootstrapped workspace is absolute" "/data/config/workspace" "$bootstrap_workspace"
docker rm -f "$BOOTSTRAP_NAME" >/dev/null 2>&1
restart_service

# ---------------------------------------------------------------------------
# A19: symlink safety
# ---------------------------------------------------------------------------
printf '\n=== A19: symlink safety ===\n'
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
assert_eq 19 "migration startup exits 0" "0" "$migration_rc"

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
assert_eq 19 "migrated symlink resolves to /data/config" "/data/config" "$migration_link"
assert_eq 19 "legacy file migrated without loss" "legacy-data" "$migration_data"
assert_eq 19 "legacy source replaced by the symlink" "source-replaced-by-symlink" "$migration_source"
assert_eq 19 "migration did not leave a legacy copy behind" "no-legacy" "$migration_legacy"
assert_eq 19 "symlink ownership fixed" "777 1000:1000" "$migration_owner"

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
assert_nonzero_status 19 "wrong-target symlink fails closed" "$wrong_target_rc"
assert_contains 19 "failure explains the wrong target" "$wrong_target_out" "refusing to retarget symlink"
assert_eq 19 "wrong-target symlink was not retargeted" "/data/elsewhere" \
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
assert_eq 19 "both-populated startup exits 0" "0" "$both_rc"
both_state="$(docker run --rm --user 0:0 --entrypoint /bin/bash \
    -v "${PROJECT}_sym_home3:/data/home" -v "${PROJECT}_sym_config3:/data/config" \
    "$IMAGE" -c '
readlink -f /data/home/.nanobot
cat /data/config/config.json
cat /data/home/.nanobot.legacy.*/old.txt
' 2>&1)"
assert_eq 19 "both-populated case still links to /data/config" "/data/config" \
    "$(printf '%s\n' "$both_state" | sed -n '1p')"
assert_eq 19 "existing config was not overwritten" "__keep__" \
    "$(printf '%s\n' "$both_state" | sed -n '2p')"
assert_eq 19 "non-empty home data preserved in legacy directory" "old-home" \
    "$(printf '%s\n' "$both_state" | sed -n '3p')"

# ---------------------------------------------------------------------------
# A20: update rejection, uv tools, cheat sheet
# ---------------------------------------------------------------------------
printf '\n=== A20: update rejection, uv, cheat sheet ===\n'
update_out="$("${COMPOSE[@]}" run --rm --no-deps -T nanobot update 2>&1)"
update_rc=$?
assert_nonzero_status 20 "nanobot update is rejected" "$update_rc"
assert_contains 20 "rejection explains it is unsupported" "$update_out" "not supported"
assert_contains 20 "rejection points at NANOBOT_VERSION" "$update_out" "NANOBOT_VERSION"

uv_out="$(exec_nanobot sh -c 'uv tool install ruff' 2>&1)"
assert_contains 20 "uv tool install ruff succeeds" "$uv_out" "Installed"
assert_eq 20 "uv tool directory is in /data/home" "0" \
    "$(exec_nanobot test -d /data/home/.local/share/uv/tools/ruff >/dev/null 2>&1; echo $?)"
assert_eq 20 "uv cache was written under /data/cache/uv" "0" \
    "$(exec_nanobot sh -c 'find /data/cache/uv -mindepth 1 -print -quit | grep -q .' >/dev/null 2>&1; echo $?)"

assert_eq 20 "/etc/nanobot-env.md is mode 0444" "444" \
    "$(exec_root stat -c '%a' /etc/nanobot-env.md)"
cheat_sheet="$(exec_root cat /etc/nanobot-env.md 2>&1)"
assert_contains 20 "cheat sheet documents pixi global install" "$cheat_sheet" "pixi global install"
assert_contains 20 "cheat sheet forbids sudo" "$cheat_sheet" "sudo"
assert_contains 20 "cheat sheet forbids apt" "$cheat_sheet" "apt"
assert_contains 20 "cheat sheet documents disposable cache" "$cheat_sheet" "disposable"
assert_contains 20 "cheat sheet documents NANOBOT_CHANNELS" "$cheat_sheet" "NANOBOT_CHANNELS"

# ---------------------------------------------------------------------------
# A21: channel dependencies from NANOBOT_CHANNELS
# ---------------------------------------------------------------------------
printf '\n=== A21: channel dependencies ===\n'
assert_eq 21 "/usr/local/bin/nanobot-channels.py is executable" "0" \
    "$(exec_nanobot test -x /usr/local/bin/nanobot-channels.py >/dev/null 2>&1; echo $?)"
assert_eq 21 "the image exposes NANOBOT_VERSION" "0.4.2" \
    "$(docker run --rm --entrypoint sh "$IMAGE" -c 'echo "$NANOBOT_VERSION"' 2>&1)"
absent_out="$(docker run --rm --entrypoint /app/.venv/bin/python "$IMAGE" \
    -c 'import discord' 2>&1)"
absent_rc=$?
assert_nonzero_status 21 "discord is absent from the image venv until installed" "$absent_rc"
assert_contains 21 "the absent import fails cleanly" "$absent_out" "ModuleNotFoundError"

cache_before="$(exec_nanobot du -sk /data/cache/uv | cut -f1)"

export NANOBOT_CHANNELS="discord,telegram,slack"
recreate_start=$SECONDS
force_recreate
recreate_seconds=$((SECONDS - recreate_start))
assert_eq 21 "compose passes NANOBOT_CHANNELS to the container" "discord,telegram,slack" \
    "$(exec_nanobot_retry printenv NANOBOT_CHANNELS || true)"

channel_logs="$(docker logs "$CID" 2>&1 || true)"
assert_contains 21 "startup logs the channel dependency install" "$channel_logs" \
    "installing channel dependencies for: discord, telegram, slack"
assert_contains 21 "startup confirms the channel dependency install" "$channel_logs" \
    "installed channel dependencies for: discord, telegram, slack"

channel_imports="$(exec_nanobot_retry /app/.venv/bin/python -c \
    'import discord, telegram, slack_sdk; print("imports-ok")' 2>&1)"
assert_eq 21 "discord, telegram, and slack_sdk import from /app/.venv" "imports-ok" \
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
assert_contains 21 "discord.py satisfies the manifest constraint" "$channel_versions" "discord.py=2."
assert_contains 21 "python-telegram-bot satisfies the manifest constraint" \
    "$channel_versions" "python-telegram-bot=22."
assert_contains 21 "slack-sdk satisfies the manifest constraint" "$channel_versions" "slack-sdk=3."

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
assert_eq 21 "the gateway does not inherit NANOBOT_CHANNELS" "absent" "$gateway_channels_env"
assert_contains 21 "nanobot status still works while NANOBOT_CHANNELS is set" \
    "$(exec_nanobot_retry sh -c 'nanobot status' 2>&1 || true)" "/data/config/config.json"

cache_after="$(exec_nanobot du -sk /data/cache/uv | cut -f1)"
if [ "$cache_after" -gt "$cache_before" ]; then
    pass 21 "channel wheels were written to /data/cache/uv (+$((cache_after - cache_before)) KB)"
else
    fail 21 "channel wheels were written to /data/cache/uv (before ${cache_before} KB, after ${cache_after} KB)"
fi
printf 'recreate to healthy with installs: %ss, cache: %s\n' \
    "$recreate_seconds" "$(exec_root du -sh /data/cache/uv 2>&1)"

since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
restart_start=$SECONDS
restart_service
restart_seconds=$((SECONDS - restart_start))
restart_logs="$(docker logs --since "$since" "$CID" 2>&1 || true)"
for name in discord telegram slack; do
    assert_contains 21 "channel '$name' dependencies already installed on restart" \
        "$restart_logs" "channel dependencies for '$name' already installed"
done
if printf '%s' "$restart_logs" | grep -Fq "installing channel dependencies"; then
    fail 21 "restart did not run uv again"
else
    pass 21 "restart did not run uv again"
fi
printf 'restart to healthy without reinstalling: %ss\n' "$restart_seconds"

offline_start=$SECONDS
offline_out="$("${COMPOSE[@]}" run --rm --no-deps -T -e UV_OFFLINE=1 nanobot /bin/true 2>&1)"
offline_rc=$?
offline_seconds=$((SECONDS - offline_start))
assert_eq 21 "a fresh container replays the install with UV_OFFLINE=1" "0" "$offline_rc"
assert_contains 21 "the offline replay installed from the cache" "$offline_out" \
    "installed channel dependencies for: discord, telegram, slack"
assert_contains 21 "the offline replay reports the uv result" "$offline_out" "uv:"
printf 'offline replay in a fresh container: %ss\n' "$offline_seconds"

export NANOBOT_CHANNELS="not-a-real-channel"
force_recreate
unknown_logs="$(docker logs "$CID" 2>&1 || true)"
assert_contains 21 "unknown channel name logs a warning" "$unknown_logs" \
    "WARNING: unknown channel(s) in NANOBOT_CHANNELS: not-a-real-channel"
assert_contains 21 "unknown channel warning names the known channels" "$unknown_logs" \
    "known channels:"
assert_contains 21 "unknown channel warning points at nanobot channels" "$unknown_logs" \
    "nanobot channels"
assert_eq 21 "container is healthy despite the unknown channel" "healthy" "$(health_status)"
assert_contains 21 "gateway still runs after the unknown channel" \
    "$(docker top "$CID" -o pid,args 2>/dev/null || true)" "nanobot-gateway"
export NANOBOT_CHANNELS=""

# ---------------------------------------------------------------------------
# A22: Homebrew on its own volume, npm global prefix
#
# Both are exercised through the env nanobot's WebUI app runner actually passes
# (nanobot/apps/cli/service.py:_subprocess_env -> HOME, LANG, TERM, PATH,
# PYTHONUNBUFFERED), not through the image env: that is the path that has to
# work, and it is the one where HOMEBREW_*/npm_config_* are absent.
#
# The formula defaults to `tree` because it is one small bottle. `jq` needs
# linux-headers/glibc/gcc/binutils (~1.1 GB of bottles) on this Homebrew; use
# NANOBOT_SMOKE_BREW_FORMULA=jq to run that heavier path deliberately.
# ---------------------------------------------------------------------------
printf '\n=== A22: brew volume, bottle install, npm prefix ===\n'
ALLOWLIST_ENV="env -i HOME=/data/home LANG=C.UTF-8 TERM=dumb PATH=/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin PYTHONUNBUFFERED=1"
BREW_FORMULA="${NANOBOT_SMOKE_BREW_FORMULA:-tree}"

mounts="$(docker inspect -f '{{range .Mounts}}{{.Type}} {{.Destination}};{{end}}' "$CID")"
assert_contains 22 "brew is a named volume at /data/brew" "$mounts" "volume /data/brew;"
assert_eq 22 "the brew wrapper is first on PATH" "/data/home/.local/bin/brew" \
    "$(exec_nanobot sh -c 'command -v brew')"
assert_eq 22 "the wrapper resolves to the image's brew entry point" \
    "/usr/local/bin/nanobot-brew" "$(exec_nanobot readlink -f /data/home/.local/bin/brew)"
assert_eq 22 "brew --prefix is /data/brew" "/data/brew" \
    "$(exec_nanobot sh -c 'brew --prefix')"
assert_contains 22 "brew --version reports Homebrew" \
    "$(exec_nanobot sh -c 'brew --version' 2>&1)" "Homebrew"

run_detached "brew install $BREW_FORMULA (app-runner env)" \
    "cd /data/home; $ALLOWLIST_ENV /bin/bash -c 'brew install $BREW_FORMULA'; echo \$? >/tmp/smoke-cmd.rc" 300
assert_eq 22 "brew install $BREW_FORMULA succeeds with the app-runner env" "0" "$DETACHED_RC"
assert_contains 22 "the bottle install reports success" \
    "$(exec_nanobot sh -c 'cat /tmp/smoke-cmd.log' 2>&1)" "$BREW_FORMULA"
assert_eq 22 "the wrapper suppresses brew's auto-update git fetch" "0" \
    "$(exec_nanobot sh -c "grep -c 'Auto-updating Homebrew' /tmp/smoke-cmd.log || true" 2>/dev/null)"

brew_which="$(exec_nanobot sh -c "$ALLOWLIST_ENV /app/.venv/bin/python -c 'import shutil, sys; print(shutil.which(sys.argv[1]) or \"\")' $BREW_FORMULA)" 2>&1)"
assert_eq 22 "shutil.which finds the bottle binary without HOMEBREW_* vars" \
    "/data/brew/bin/$BREW_FORMULA" "$brew_which"
assert_contains 22 "the bottle binary runs" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV $BREW_FORMULA --version" 2>&1)" "$BREW_FORMULA"

assert_eq 22 "npm prefix is recorded in ~/.npmrc" "prefix=/data/home/.local" \
    "$(exec_nanobot sh -c "grep -x 'prefix=/data/home/.local' /data/home/.npmrc" 2>/dev/null)"
run_detached "npm install -g cowsay@1.5.0 (app-runner env)" \
    "cd /data/home; $ALLOWLIST_ENV /bin/bash -c 'npm install -g cowsay@1.5.0'; echo \$? >/tmp/smoke-cmd.rc" 180
assert_eq 22 "npm install -g succeeds with the app-runner env" "0" "$DETACHED_RC"
assert_eq 22 "npm global bins land in ~/.local/bin" "/data/home/.local/bin/cowsay" \
    "$(exec_nanobot sh -c 'command -v cowsay')"
assert_contains 22 "the npm-installed CLI runs" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV cowsay -t smoke" 2>&1)" "< smoke >"

# The entrypoint seeds the workspace from nanobot's templates and adds one
# marked rules block before the gateway starts.
assert_eq 22 "the workspace AGENTS.md carries exactly one rules block" "1" \
    "$(exec_nanobot sh -c 'grep -c nanobot-image-env:begin /data/config/workspace/AGENTS.md')"
exec_nanobot sh -c '/app/.venv/bin/python -B /usr/local/bin/workspace-agents-env.py --seed-templates /data/config/workspace' >/dev/null 2>&1
exec_nanobot sh -c '/app/.venv/bin/python -B /usr/local/bin/workspace-agents-env.py --seed-templates /data/config/workspace' >/dev/null 2>&1
assert_eq 22 "re-running the rules helper does not duplicate the block" "1" \
    "$(exec_nanobot sh -c 'grep -c nanobot-image-env:begin /data/config/workspace/AGENTS.md')"
assert_eq 22 "the block is closed exactly once" "1" \
    "$(exec_nanobot sh -c 'grep -c nanobot-image-env:end /data/config/workspace/AGENTS.md')"
assert_contains 22 "the block states the no-apt/no-sudo rule" \
    "$(exec_nanobot sh -c 'cat /data/config/workspace/AGENTS.md')" 'no `apt`/`apt-get`/`apk`'

force_recreate
assert_eq 22 "brew still resolves after a recreate" "/data/home/.local/bin/brew" \
    "$(exec_nanobot_retry sh -c 'command -v brew')"
assert_eq 22 "the brew wrapper is still linked after the recreate" \
    "/usr/local/bin/nanobot-brew" \
    "$(exec_nanobot_retry readlink -f /data/home/.local/bin/brew)"
assert_eq 22 "the brew bottle survives the recreate" "/data/brew/bin/$BREW_FORMULA" \
    "$(exec_nanobot_retry sh -c "env -i HOME=/data/home LANG=C.UTF-8 TERM=dumb PATH=/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin PYTHONUNBUFFERED=1 /app/.venv/bin/python -c 'import shutil, sys; print(shutil.which(sys.argv[1]) or \"\")' $BREW_FORMULA" 2>&1)"
assert_contains 22 "the brew bottle still runs after the recreate" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV $BREW_FORMULA --version" 2>&1)" "$BREW_FORMULA"
assert_eq 22 "npm prefix survives the recreate" "/data/home/.local" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV npm prefix -g" 2>&1)"
assert_contains 22 "the npm-installed CLI still runs after the recreate" \
    "$(exec_nanobot sh -c "$ALLOWLIST_ENV cowsay -t again" 2>&1)" "< again >"

# ---------------------------------------------------------------------------
printf '\n=== summary ===\n'
printf 'passed checks: %d\n' "$PASSED"
printf 'failed checks: %d\n' "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    exit 1
fi
printf 'ALL A1-A22 PASSED\n'

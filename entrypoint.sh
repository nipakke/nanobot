#!/usr/bin/env bash
# nanobot container entrypoint.
#
# Starts as root only for the setup phase (create/chown the five persistent
# trees and establish the ~/.nanobot -> /data/config symlink), then drops to
# the non-root nanobot user with setpriv. The unprivileged phase applies pixi
# extras, bootstraps the config when needed, and execs the requested command.
set -euo pipefail

readonly NANOBOT_USER="nanobot"
readonly NANOBOT_GROUP="nanobot"
readonly LOG_PREFIX="[entrypoint]"
readonly SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Never resolve commands from nanobot-writable directories while running as root.
if [ "${EUID:-$(/usr/bin/id -u)}" -eq 0 ]; then
    export PATH="$SYSTEM_PATH"
fi

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARNING: %s\n' "$LOG_PREFIX" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

strip_trailing_slashes() {
    local p="$1"
    while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
        p="${p%/}"
    done
    printf '%s\n' "$p"
}

reject_symlink_path() {
    local p="$1"
    if [ -L "$p" ]; then
        die "refusing to use symlink $p as a data directory"
    fi
}

apply_defaults() {
    export HOME="$(strip_trailing_slashes "${HOME:-/data/home}")"
    export NANOBOT_HOME="$(strip_trailing_slashes "${NANOBOT_HOME:-/data/config}")"
    export PIXI_HOME="$(strip_trailing_slashes "${PIXI_HOME:-/data/pixi}")"
    export XDG_CACHE_HOME="$(strip_trailing_slashes "${XDG_CACHE_HOME:-/data/cache}")"
    export PIXI_CACHE_DIR="$(strip_trailing_slashes "${PIXI_CACHE_DIR:-$XDG_CACHE_HOME/pixi}")"
    export UV_CACHE_DIR="$(strip_trailing_slashes "${UV_CACHE_DIR:-$XDG_CACHE_HOME/uv}")"
    export UV_TOOL_DIR="$(strip_trailing_slashes "${UV_TOOL_DIR:-$HOME/.local/share/uv/tools}")"
    export UV_TOOL_BIN_DIR="$(strip_trailing_slashes "${UV_TOOL_BIN_DIR:-$HOME/.local/bin}")"
    export PIP_CACHE_DIR="$(strip_trailing_slashes "${PIP_CACHE_DIR:-$XDG_CACHE_HOME/pip}")"
    export PYTHONPYCACHEPREFIX="$(strip_trailing_slashes "${PYTHONPYCACHEPREFIX:-$XDG_CACHE_HOME/pycache}")"
    export HOMEBREW_PREFIX="$(strip_trailing_slashes "${HOMEBREW_PREFIX:-/data/brew}")"
    export HOMEBREW_CELLAR="$(strip_trailing_slashes "${HOMEBREW_CELLAR:-$HOMEBREW_PREFIX/Cellar}")"
    export HOMEBREW_REPOSITORY="$(strip_trailing_slashes "${HOMEBREW_REPOSITORY:-$HOMEBREW_PREFIX/Homebrew}")"
    export HOMEBREW_CACHE="$(strip_trailing_slashes "${HOMEBREW_CACHE:-$XDG_CACHE_HOME/brew}")"
    export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"
    export HOMEBREW_NO_ANALYTICS="${HOMEBREW_NO_ANALYTICS:-1}"
    export HOMEBREW_NO_ENV_HINTS="${HOMEBREW_NO_ENV_HINTS:-1}"
    export npm_config_prefix="${npm_config_prefix:-$HOME/.local}"
    export npm_config_cache="${npm_config_cache:-$HOME/.npm}"
    export PIXI_NO_TELEMETRY="${PIXI_NO_TELEMETRY:-1}"
    local uid gid
    uid="$(id -u "$NANOBOT_USER" 2>/dev/null || true)"
    gid="$(getent group "$NANOBOT_GROUP" 2>/dev/null | cut -d: -f3 || true)"
    [ -n "$gid" ] || gid="$(id -g "$NANOBOT_USER" 2>/dev/null || true)"
    export NANOBOT_UID="${uid:-${NANOBOT_UID:-1000}}"
    export NANOBOT_GID="${gid:-${NANOBOT_GID:-1000}}"
}

is_mount_point() {
    local path="$1"
    awk -v p="$path" '$5 == p { found = 1 } END { exit(found ? 0 : 1) }' \
        /proc/self/mountinfo 2>/dev/null
}

# A fresh Docker named volume mounted at /data/config is seeded from the image
# directory, which already contains an empty workspace/. That must not count as
# user data, or the very first migration would always be misclassified.
target_has_data() {
    local target="$1" entry
    for entry in "$target"/* "$target"/.[!.]* "$target"/..?*; do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        if [ "$entry" = "$target/workspace" ] && [ -d "$entry" ] &&
           [ -z "$(ls -A "$entry")" ]; then
            continue
        fi
        return 0
    done
    return 1
}

# Establish $HOME/.nanobot -> $NANOBOT_HOME without ever clobbering data.
# Never retargets a symlink, never touches a mount point, and preserves
# non-empty user data instead of deleting it.
establish_symlink() {
    local link="$HOME/.nanobot"
    local target="$NANOBOT_HOME"
    local raw resolved target_resolved legacy

    if [ -L "$link" ]; then
        raw="$(readlink "$link")"
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        target_resolved="$(readlink -f "$target" 2>/dev/null || true)"
        if [ "$raw" = "$target" ] ||
           { [ -n "$resolved" ] && [ -n "$target_resolved" ] && [ "$resolved" = "$target_resolved" ]; }; then
            log "symlink $link -> $target already in place"
            return 0
        fi
        die "refusing to retarget symlink $link (currently -> $raw); expected $target. Move it aside manually."
    fi

    if [ -e "$link" ]; then
        if is_mount_point "$link"; then
            die "refusing to touch mount point $link; mount the data at $target instead."
        fi

        if [ -d "$link" ]; then
            if [ -z "$(ls -A "$link")" ]; then
                rmdir "$link"
                log "removed empty directory $link"
            elif ! target_has_data "$target"; then
                # Migration: only when the intended target holds no user data.
                # Stage into a temp dir inside $target so a mid-copy failure
                # never leaves partial user data behind. Copy child entries
                # (not $link/.) with --preserve=mode,links so file modes and
                # symlinks survive without touching $target's root metadata
                # (which requires CAP_FOWNER). Ownership is fixed below.
                local stage entry
                local -a entries=()
                stage="$target/.nanobot-migration.$$"
                mkdir -p "$stage" || die "could not create migration staging dir $stage"
                for entry in "$link"/* "$link"/.[!.]* "$link"/..?*; do
                    if [ -e "$entry" ] || [ -L "$entry" ]; then
                        entries+=("$entry")
                    fi
                done
                if [ "${#entries[@]}" -gt 0 ]; then
                    if ! cp -RP --preserve=mode,links -- "${entries[@]}" "$stage/"; then
                        rm -rf "$stage"
                        die "migration copy from $link to $target failed; source left untouched"
                    fi
                fi
                local cwd_was_workspace=0
                if [ -d "$target/workspace" ] && [ -z "$(ls -A "$target/workspace")" ] &&
                   { [ -e "$stage/workspace" ] || [ -L "$stage/workspace" ]; }; then
                    if [ "$(stat -c '%d:%i' . 2>/dev/null || true)" = "$(stat -c '%d:%i' "$target/workspace" 2>/dev/null || true)" ]; then
                        cwd_was_workspace=1
                    fi
                    rmdir "$target/workspace" || {
                        rm -rf "$stage"
                        die "could not replace empty $target/workspace during migration"
                    }
                fi
                for entry in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do
                    if [ -e "$entry" ] || [ -L "$entry" ]; then
                        mv -- "$entry" "$target/" || die "could not move migrated entry $entry into $target"
                    fi
                done
                if [ "$cwd_was_workspace" -eq 1 ]; then
                    if [ -d "$target/workspace" ]; then
                        cd "$target/workspace"
                    else
                        cd "$target"
                    fi
                fi
                rmdir "$stage" || die "could not remove migration staging dir $stage"
                rm -rf "$link" || die "could not remove $link after migration"
                log "migrated contents of $link into $target"
            else
                legacy="$HOME/.nanobot.legacy.$(date +%Y%m%d-%H%M%S)"
                [ -e "$legacy" ] && legacy="${legacy}.$$"
                mv "$link" "$legacy" || die "could not move $link aside"
                log "kept existing $link as $legacy because $target already has data"
            fi
        elif [ -f "$link" ]; then
            legacy="$HOME/.nanobot.legacy.$(date +%Y%m%d-%H%M%S)"
            [ -e "$legacy" ] && legacy="${legacy}.$$"
            mv "$link" "$legacy" || die "could not move $link aside"
            log "kept existing file $link as $legacy"
        else
            die "refusing to replace special file $link"
        fi
    fi

    ln -s "$target" "$link" || die "could not create symlink $link -> $target"
    log "created symlink $link -> $target"
}

# Chown only entries whose UID/GID differ; keeps /data/pixi and /data/cache
# cheap on later boots. find does not follow the .nanobot symlink.
fix_ownership() {
    local dir
    if [ -d /data ] && [ ! -L /data ]; then
        find /data -maxdepth 0 \( ! -uid "$NANOBOT_UID" -o ! -gid "$NANOBOT_GID" \) \
            -exec chown -h "$NANOBOT_UID:$NANOBOT_GID" {} +
    fi
    local -a roots=("$NANOBOT_HOME" "$HOME" "$PIXI_HOME" "$HOMEBREW_PREFIX" "$XDG_CACHE_HOME")
    for dir in "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$HOMEBREW_CACHE" "$PYTHONPYCACHEPREFIX"; do
        case "$dir" in
            "$XDG_CACHE_HOME"|"$XDG_CACHE_HOME"/*) ;;
            *) roots+=("$dir") ;;
        esac
    done
    for dir in "${roots[@]}"; do
        reject_symlink_path "$dir"
        [ -d "$dir" ] || continue
        find "$dir" \( ! -uid "$NANOBOT_UID" -o ! -gid "$NANOBOT_GID" \) \
            -exec chown -h "$NANOBOT_UID:$NANOBOT_GID" {} +
    done
}

root_phase() {
    local dir
    log "setup as uid=$(id -u) gid=$(id -g)"

    for dir in /data \
        "$NANOBOT_HOME" "$NANOBOT_HOME/workspace" \
        "$HOME" "$HOME/.local" "$HOME/.local/bin" "$HOME/.local/share" \
        "$HOME/.local/share/uv" "$HOME/.local/share/uv/tools" \
        "$PIXI_HOME" \
        "$HOMEBREW_PREFIX" \
        "$XDG_CACHE_HOME" \
        "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$HOMEBREW_CACHE" \
        "$PYTHONPYCACHEPREFIX"; do
        reject_symlink_path "$dir"
    done

    mkdir -p "$NANOBOT_HOME" \
        "$HOME/.local/bin" \
        "$HOME/.local/share/uv/tools" \
        "$PIXI_HOME" \
        "$HOMEBREW_PREFIX" \
        "$XDG_CACHE_HOME" \
        "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" "$HOMEBREW_CACHE" \
        "$PYTHONPYCACHEPREFIX"

    # The symlink policy runs before creating config/workspace so a pre-seeded
    # $HOME/.nanobot directory can still be migrated into an empty target.
    establish_symlink
    mkdir -p "$NANOBOT_HOME/workspace"

    fix_ownership

    if ! setpriv --reuid="$NANOBOT_USER" --regid="$NANOBOT_GROUP" --init-groups true; then
        die "cannot drop privileges to $NANOBOT_USER; refusing to run as root"
    fi

    log "dropping privileges to $NANOBOT_USER and re-executing the entrypoint"
    exec setpriv --reuid="$NANOBOT_USER" --regid="$NANOBOT_GROUP" --init-groups "$0" "$@"
}

ownership_hint() {
    local path="$1"
    printf '%s ERROR: %s is not writable by uid=%s gid=%s. Named volumes are fixed automatically by the root setup phase; for bind mounts, chown the host directory to %s:%s before starting.\n' \
        "$LOG_PREFIX" "$path" "$(id -u)" "$(id -g)" "$NANOBOT_UID" "$NANOBOT_GID" >&2
    exit 1
}

ensure_writable_dir() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || ownership_hint "$dir"
    [ -w "$dir" ] || ownership_hint "$dir"
}

ensure_symlink() {
    local link="$HOME/.nanobot"
    local target="$NANOBOT_HOME"

    if [ -L "$link" ]; then
        local resolved target_resolved
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        target_resolved="$(readlink -f "$target" 2>/dev/null || true)"
        [ -n "$resolved" ] && [ "$resolved" = "$target_resolved" ] && return 0
        die "symlink $link does not point to $target; fix it before starting (uid=$(id -u))"
    fi
    if [ -e "$link" ]; then
        die "$link exists but is not a symlink to $target; fix it before starting (uid=$(id -u))"
    fi
    ln -s "$target" "$link" ||
        die "could not create $link -> $target (uid=$(id -u) gid=$(id -g)); chown /data/home to $NANOBOT_UID:$NANOBOT_GID"
}

# Extract the package name from a pixi spec: strip channel::, then bracketed
# build constraints, then version constraints.
pixi_package_name() {
    local spec="$1"
    spec="${spec#*::}"
    spec="${spec%%\[*}"
    spec="${spec%%[=<>!~]*}"
    printf '%s\n' "$spec"
}

pixi_package_present() {
    local name="$1"
    local manifest="$PIXI_HOME/manifests/pixi-global.toml"

    [ -d "$PIXI_HOME/envs/$name" ] && return 0
    if [ -f "$manifest" ] &&
       { grep -Fqx "[envs.$name]" "$manifest" || grep -Fqx "[envs.\"$name\"]" "$manifest"; }; then
        return 0
    fi
    return 1
}

apply_extra_pixi_packages() {
    local raw="${EXTRA_PIXI_PACKAGES:-}"
    local -a specs=()
    local spec name

    [ -n "$raw" ] || return 0
    raw="${raw//,/ }"
    raw="${raw//$'\n'/ }"

    # Split on whitespace without pathname expansion (e.g. jq=1.7.*).
    read -r -a specs <<< "$raw" || true
    [ "${#specs[@]}" -gt 0 ] || return 0
    for spec in "${specs[@]}"; do
        name="$(pixi_package_name "$spec")"
        if [ -z "$name" ]; then
            warn "cannot derive a package name from EXTRA_PIXI_PACKAGES entry '$spec'; skipping"
            continue
        fi
        if pixi_package_present "$name"; then
            log "pixi package '$name' already present at $PIXI_HOME/envs/$name"
            continue
        fi
        log "installing pixi package: $spec"
        if ! pixi global install "$spec"; then
            warn "pixi global install '$spec' failed; the gateway will still start. Retry with: pixi global install '$spec'"
        fi
    done
}

# Install the Python dependencies declared by the channels named in
# NANOBOT_CHANNELS. The helper resolves each name through nanobot's own channel
# registry and installs the declared requirements into /app/.venv with uv,
# using the persistent /data/cache/uv cache. It is a no-op when every
# requirement is already present, and it never aborts startup: any failure is a
# warning and the gateway still runs.
apply_channel_dependencies() {
    local channels="${NANOBOT_CHANNELS:-}"

    if [ -n "$channels" ]; then
        /app/.venv/bin/python /usr/local/bin/nanobot-channels.py "$channels" ||
            warn "channel dependency helper exited nonzero; the gateway will still start"
    fi

    # NANOBOT_CHANNELS is an entrypoint-only knob. nanobot's settings read the
    # NANOBOT_ prefix, so this name would be parsed as the whole channels
    # mapping, and any value (even empty) fails validation. Drop it before the
    # gateway or a bootstrap run inherits it. Ad-hoc `docker exec` processes get
    # the container-level env instead, so the venv sitecustomize shim also
    # removes it at interpreter startup.
    unset NANOBOT_CHANNELS
}

# npm resolves its global prefix from `npm_config_prefix` in the environment, or
# from the user config at $HOME/.npmrc. The WebUI app runner starts npm with a
# minimal env (HOME, LANG, TERM, PATH, PYTHONUNBUFFERED), so the image's
# npm_config_prefix never arrives there and npm would fall back to its builtin
# prefix inside the node environment, which is not on PATH. HOME is persistent
# and is passed through, so record both settings in ~/.npmrc. Keys that are
# already set are never rewritten: an operator's own values win.
configure_npm() {
    local npmrc="$HOME/.npmrc" key value
    for key in prefix cache; do
        case "$key" in
            prefix) value="$npm_config_prefix" ;;
            cache) value="$npm_config_cache" ;;
        esac
        if [ -f "$npmrc" ] && grep -Fqx "$key=$value" "$npmrc"; then
            continue
        fi
        if [ -f "$npmrc" ] && grep -q "^$key[[:space:]]*=" "$npmrc"; then
            warn "$npmrc already sets $key; keeping that value instead of $value"
            continue
        fi
        if [ ! -f "$npmrc" ]; then
            printf '# Written by the nanobot entrypoint; safe to edit.\n' >"$npmrc"
        elif [ -s "$npmrc" ] && [ "$(tail -c 1 "$npmrc" | wc -l)" -eq 0 ]; then
            printf '\n' >>"$npmrc"
        fi
        printf '%s=%s\n' "$key" "$value" >>"$npmrc"
        log "configured npm $key=$value in $npmrc"
    done
}

# brew falls back to $HOME/.cache/Homebrew when HOMEBREW_CACHE is absent from
# its environment (again the WebUI path). Point that at the disposable cache
# tree so bottle downloads do not accumulate in the home volume. Existing data
# is never moved or replaced.
ensure_brew_cache_link() {
    local link="$HOME/.cache/Homebrew"
    local target="$HOMEBREW_CACHE"

    if [ -L "$link" ]; then
        local resolved target_resolved
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        target_resolved="$(readlink -f "$target" 2>/dev/null || true)"
        if [ -n "$resolved" ] && [ "$resolved" = "$target_resolved" ]; then
            return 0
        fi
        warn "$link points elsewhere; brew will cache there instead of $target"
        return 0
    fi
    if [ -e "$link" ]; then
        warn "$link exists and is not a symlink; leaving it in place"
        return 0
    fi
    mkdir -p "$HOME/.cache" && ln -s "$target" "$link" ||
        { warn "could not link $link -> $target"; return 0; }
    log "linked $link -> $target"
}

# Seed $HOMEBREW_PREFIX from the image when empty (for example on a fresh host
# bind mount such as ./data:/data, which Docker does not auto-populate).
# Copy bin/ last so $HOMEBREW_PREFIX/bin/brew only exists once the rest of the
# seed (including portable Ruby) has been copied cleanly.
seed_brew() {
    local seed="/usr/local/share/nanobot-brew-seed"
    local entry
    local -a entries=()

    [ -d "$seed" ] || return 0
    [ -x "$HOMEBREW_PREFIX/bin/brew" ] && return 0

    for entry in "$seed"/* "$seed"/.[!.]* "$seed"/..?*; do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        [ "$entry" = "$seed/bin" ] && continue
        entries+=("$entry")
    done
    [ "${#entries[@]}" -gt 0 ] || [ -e "$seed/bin" ] || return 0

    log "seeding Homebrew into $HOMEBREW_PREFIX"
    if [ "${#entries[@]}" -gt 0 ] &&
       ! cp -RPf --preserve=mode,links -- "${entries[@]}" "$HOMEBREW_PREFIX/"; then
        rm -f "$HOMEBREW_PREFIX/bin/brew" 2>/dev/null || true
        warn "could not seed Homebrew into $HOMEBREW_PREFIX; brew may be unavailable"
        return 0
    fi
    if [ -d "$seed/bin" ] &&
       ! cp -RPf --preserve=mode,links -- "$seed/bin" "$HOMEBREW_PREFIX/"; then
        rm -f "$HOMEBREW_PREFIX/bin/brew" 2>/dev/null || true
        warn "could not finish seeding Homebrew bin into $HOMEBREW_PREFIX; brew may be unavailable"
        return 0
    fi
}

# $HOME/.local/bin/brew -> /usr/local/bin/nanobot-brew. That wrapper restores
# the image's HOMEBREW_* defaults (notably HOMEBREW_NO_AUTO_UPDATE) for the
# WebUI app runner, whose env carries none of them; without it every WebUI
# `brew install` starts with a git auto-update inside /data/brew, which can
# destabilise Docker Desktop on Windows/WSL. It sits before /data/brew/bin on PATH.
ensure_brew_wrapper() {
    local link="$HOME/.local/bin/brew"
    local target="/usr/local/bin/nanobot-brew"

    [ -x "$target" ] || return 0
    if [ -L "$link" ]; then
        local resolved target_resolved
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        target_resolved="$(readlink -f "$target" 2>/dev/null || true)"
        if [ -n "$resolved" ] && [ "$resolved" = "$target_resolved" ]; then
            return 0
        fi
        warn "$link points elsewhere; leaving it (brew may auto-update)"
        return 0
    fi
    if [ -e "$link" ]; then
        warn "$link exists and is not a symlink; leaving it (brew may auto-update)"
        return 0
    fi
    ln -s "$target" "$link" || { warn "could not link $link -> $target"; return 0; }
    log "linked $link -> $target"
}

# The agent's context only includes <workspace>/AGENTS.md (plus SOUL.md and
# USER.md); /etc/nanobot-env.md is never read automatically. nanobot creates
# those workspace files from its bundled templates inside the gateway, which
# starts after this phase, so the helper seeds them first via nanobot's own
# idempotent sync (only missing files are written) and then keeps a marked rules
# block in AGENTS.md. It never duplicates the block and never rewrites text
# outside it.
ensure_workspace_agent_rules() {
    local helper="/usr/local/bin/workspace-agents-env.py"

    [ -x "$helper" ] || return 0
    /app/.venv/bin/python -B "$helper" --seed-templates "$NANOBOT_HOME/workspace" ||
        warn "workspace AGENTS.md helper failed; the gateway still starts"
}

reject_update() {
    cat >&2 <<'EOF'
[entrypoint] ERROR: in-container `nanobot update` is not supported.
[entrypoint] The nanobot install lives in /app/.venv inside the image and
[entrypoint] would be lost on the next container recreate.
[entrypoint] Rebuild the image with a new NANOBOT_VERSION build arg instead.
EOF
    exit 1
}

unprivileged_phase() {
    local dir

    log "running as uid=$(id -u) gid=$(id -g)"

    for dir in "$NANOBOT_HOME" \
        "$NANOBOT_HOME/workspace" \
        "$HOME" "$HOME/.local/bin" "$HOME/.local/share/uv/tools" \
        "$PIXI_HOME" \
        "$HOMEBREW_PREFIX" \
        "$XDG_CACHE_HOME" "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$PIP_CACHE_DIR" \
        "$PYTHONPYCACHEPREFIX" "$HOMEBREW_CACHE"; do
        ensure_writable_dir "$dir"
    done

    ensure_symlink
    export PATH="$PIXI_HOME/bin:$HOME/.local/bin:$HOMEBREW_PREFIX/bin:/app/.venv/bin:$SYSTEM_PATH"

    if [ "$#" -eq 0 ]; then
        set -- gateway
    fi

    case "$1" in
        nanobot|*/nanobot) ;;
        gateway|webui|agent|status|onboard|channels|plugins|provider|trigger|update|remote|completion)
            set -- nanobot "$@" ;;
        -*) set -- nanobot "$@" ;;
    esac

    local subcommand="" bootstrap_home="$NANOBOT_HOME"
    if [ "$1" = "nanobot" ] || [[ "$1" == */nanobot ]]; then
        local -a args=("$@")
        local idx=1
        while [ "$idx" -lt "${#args[@]}" ]; do
            case "${args[$idx]}" in
                --home)
                    if [ $((idx + 1)) -lt "${#args[@]}" ]; then
                        bootstrap_home="${args[$((idx + 1))]}"
                    fi
                    idx=$((idx + 2))
                    ;;
                --home=*)
                    bootstrap_home="${args[$idx]#--home=}"
                    idx=$((idx + 1))
                    ;;
                -*) idx=$((idx + 1)) ;;
                *) subcommand="${args[$idx]}"; break ;;
            esac
        done

        if [ "$subcommand" = "update" ]; then
            reject_update
        fi
    fi

    configure_npm
    seed_brew
    ensure_brew_cache_link
    ensure_brew_wrapper
    ensure_workspace_agent_rules

    apply_extra_pixi_packages
    apply_channel_dependencies

    if { [ "$subcommand" = "gateway" ] || [ "$subcommand" = "webui" ]; } &&
       [ ! -f "$bootstrap_home/config.json" ]; then
        log "bootstrapping config at $bootstrap_home/config.json"
        NANOBOT_HOME="$bootstrap_home" /app/.venv/bin/python /usr/local/bin/nanobot-bootstrap.py ||
            die "config bootstrap failed"
    fi

    exec "$@"
}

apply_defaults

if [ "$(id -u)" -eq 0 ]; then
    root_phase "$@"
else
    unprivileged_phase "$@"
fi

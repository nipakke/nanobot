#!/usr/bin/env bash
# nanobot container entrypoint.
#
# Starts as root only for the setup phase (create/chown the four persistent
# trees and establish the ~/.nanobot -> /data/config symlink), then drops to
# the non-root nanobot user with setpriv. The unprivileged phase applies pixi
# extras, bootstraps the config when needed, and execs the requested command.
set -euo pipefail

readonly NANOBOT_USER="nanobot"
readonly NANOBOT_GROUP="nanobot"
readonly LOG_PREFIX="[entrypoint]"

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARNING: %s\n' "$LOG_PREFIX" "$*" >&2; }
die() { printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2; exit 1; }

apply_defaults() {
    export HOME="${HOME:-/data/home}"
    export NANOBOT_HOME="${NANOBOT_HOME:-/data/config}"
    export PIXI_HOME="${PIXI_HOME:-/data/pixi}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/data/cache}"
    export PIXI_CACHE_DIR="${PIXI_CACHE_DIR:-$XDG_CACHE_HOME/pixi}"
    export UV_CACHE_DIR="${UV_CACHE_DIR:-$XDG_CACHE_HOME/uv}"
    export UV_TOOL_DIR="${UV_TOOL_DIR:-$HOME/.local/share/uv/tools}"
    export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}"
    export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$XDG_CACHE_HOME/pip}"
    export PIXI_NO_TELEMETRY="${PIXI_NO_TELEMETRY:-1}"
    export NANOBOT_UID="${NANOBOT_UID:-1000}"
    export NANOBOT_GID="${NANOBOT_GID:-1000}"
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
                # Ownership is fixed by the scan below; preserving metadata on
                # the target root needs CAP_FOWNER, which is deliberately not
                # granted. Copy contents and symlinks only.
                cp -R --preserve=links "$link/." "$target/" ||
                    die "migration copy from $link to $target failed; source left untouched"
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
    for dir in "$NANOBOT_HOME" "$HOME" "$PIXI_HOME" "$XDG_CACHE_HOME"; do
        [ -d "$dir" ] || continue
        find "$dir" \( ! -uid "$NANOBOT_UID" -o ! -gid "$NANOBOT_GID" \) \
            -exec chown -h "$NANOBOT_UID:$NANOBOT_GID" {} +
    done
    if [ -L "$HOME/.nanobot" ]; then
        chown -h "$NANOBOT_UID:$NANOBOT_GID" "$HOME/.nanobot"
    fi
}

root_phase() {
    log "setup as uid=$(id -u) gid=$(id -g)"

    mkdir -p "$NANOBOT_HOME" \
        "$HOME/.local/bin" \
        "$HOME/.local/share/uv/tools" \
        "$PIXI_HOME" \
        "$XDG_CACHE_HOME/pixi" "$XDG_CACHE_HOME/uv" "$XDG_CACHE_HOME/pip"

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
    if [ -f "$manifest" ] && grep -qx "\[envs\.$name\]" "$manifest"; then
        return 0
    fi
    return 1
}

apply_extra_pixi_packages() {
    local raw="${EXTRA_PIXI_PACKAGES:-}"
    local spec name

    [ -n "$raw" ] || return 0
    raw="${raw//,/ }"

    # Word splitting is intentional: commas and whitespace both separate specs.
    for spec in $raw; do
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
        "$XDG_CACHE_HOME" "$XDG_CACHE_HOME/pixi" "$XDG_CACHE_HOME/uv" "$XDG_CACHE_HOME/pip"; do
        ensure_writable_dir "$dir"
    done

    ensure_symlink
    export PATH="$PIXI_HOME/bin:$HOME/.local/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    apply_extra_pixi_packages

    if [ "$#" -eq 0 ]; then
        set -- gateway
    fi

    case "$1" in
        nanobot) ;;
        gateway|webui|agent|status|onboard|channels|plugins|provider|trigger|update|remote|completion)
            set -- nanobot "$@" ;;
        -*) set -- nanobot "$@" ;;
    esac

    if [ "$1" = "nanobot" ]; then
        local -a args=("$@")
        local idx=1 subcommand=""
        while [ "$idx" -lt "${#args[@]}" ]; do
            case "${args[$idx]}" in
                --home) idx=$((idx + 2)) ;;
                --home=*) idx=$((idx + 1)) ;;
                -*) idx=$((idx + 1)) ;;
                *) subcommand="${args[$idx]}"; break ;;
            esac
        done

        if [ "$subcommand" = "update" ]; then
            reject_update
        fi

        if { [ "$subcommand" = "gateway" ] || [ "$subcommand" = "webui" ]; } &&
           [ ! -f "$NANOBOT_HOME/config.json" ]; then
            log "bootstrapping config at $NANOBOT_HOME/config.json"
            /app/.venv/bin/python /usr/local/bin/nanobot-bootstrap.py ||
                die "config bootstrap failed"
        fi
    fi

    exec "$@"
}

apply_defaults

if [ "$(id -u)" -eq 0 ]; then
    root_phase "$@"
else
    unprivileged_phase "$@"
fi

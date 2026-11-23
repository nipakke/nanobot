# nanobot + pixi Docker image — design

Date: 2026-11-23
Status: implemented and verified (126 acceptance checks passed)
Revision: 3 (four-way persistent split, root→setpriv entrypoint)

## Intent

Run `nanobot-ai==0.4.2` in a reproducible Docker container with:

- four independent persistent trees: config, home, pixi tools, disposable cache;
- pixi as the supported way for the bot to install native/CLI tools at runtime;
- a dedicated non-root `nanobot` user with no `sudo` and no passwordless
  escalation;
- a root entrypoint that exists only long enough to create/chown the persistent
  trees and install the `~/.nanobot -> /data/config` symlink, then drops to
  `nanobot` via `setpriv`;
- an image whose nanobot install (`/app/.venv`) is baked into the image and
  ephemeral (writable by `nanobot` for channel installs), upgraded only by
  changing the image tag.

## Goals

- Persistent layout:

  | Container path | Environment | Contents | Wipe effect |
  |---|---|---|---|
  | `/data/config` | `NANOBOT_HOME=/data/config` (image-level helper variable) | nanobot config, sessions, memory, workspace | resets config/history; home/pixi/cache survive |
  | `/data/home` | `HOME=/data/home`, `UV_TOOL_DIR=/data/home/.local/share/uv/tools`, `UV_TOOL_BIN_DIR=/data/home/.local/bin` | dotfiles, SSH/CLI config, user files, uv tools | resets home; config/pixi/cache survive |
  | `/data/pixi` | `PIXI_HOME=/data/pixi` | pixi global envs, exposed binaries, global manifest | resets tools; config/home/cache survive |
  | `/data/cache` | `XDG_CACHE_HOME=/data/cache`, `PIXI_CACHE_DIR=/data/cache/pixi`, `UV_CACHE_DIR=/data/cache/uv`, `PIP_CACHE_DIR=/data/cache/pip` | 100% disposable caches | safe to delete; tools/config survive |

- `PATH` starts with `/data/pixi/bin`, then `/data/home/.local/bin`, then
  `/app/.venv/bin`, so runtime-installed tools are visible to the running
  gateway immediately.
- `/data/home/.nanobot` is a symlink to `/data/config`. This makes the gateway
  and ad-hoc `nanobot` commands use `/data/config` without a wrapper or
  `--home` flag.
- Root entrypoint chowns fresh root-owned named volumes to
  `nanobot:nanobot`, then drops privileges. No `sudo` anywhere.
- `/app/.venv` stays in the image layer (no volume), is owned by `nanobot`, and
  is therefore writable for channel dependency installs, but disappears on
  image upgrade/recreation.
- First `gateway`/`webui` start creates a config with `0.0.0.0` bindings and a
  usable WebUI token via nanobot's own bootstrap.
- Four volumes in Compose; a separate build overlay for local builds; the base
  Compose file never builds, so Portainer only pulls.
- Bot-readable `/etc/nanobot-env.md` cheat sheet baked at mode 0444.
- Docker HEALTHCHECK using `/app/.venv/bin/python` (no curl dependency).

## Non-goals / anti-goals

- No `sudo`, no passwordless escalation, no setuid helpers.
- No runtime `apt`/`apk` installs for tools; pixi is the supported path.
- Do not mount a volume over `/app/.venv`.
- No Alpine base: conda-forge native packages and nanobot's bundled TUI
  binaries need glibc.
- No runtime `nanobot update`: changes would live in the container layer and
  be lost. Rebuild with a new `NANOBOT_VERSION`.
- No Kubernetes/TLS/reverse-proxy setup.

## Approaches considered

1. **Root entrypoint → `setpriv` (chosen).** The entrypoint starts as root only
   to create/chown the four trees and establish the symlink, then drops to
   `nanobot`. This is the only approach that handles fresh root-owned named
   volumes and bind mounts without `sudo` while keeping the agent non-root.
2. **Pure non-root image.** Rejected: it cannot chown root-owned volumes and
   would fail on first boot.
3. **Runtime PUID/PGID remapping.** Rejected in favor of a fixed named user
   with build-arg UID/GID; remapping adds root-entrypoint complexity without a
   requirement for arbitrary host UIDs.
4. **Single `/data` tree with symlinks.** Rejected: the operator asked for
   independent reset domains; four volumes make "wipe only pixi/cache"
   unambiguous.
5. **Shared pixi `extra` environment for `EXTRA_PIXI_PACKAGES`.** Rejected:
   one tool's dependency conflict would break every extra; per-package envs
   isolate them.
6. **CLI wrapper injecting `--home`.** Rejected: the symlink covers filesystem
   resolution; an extra shim is limited to the venv's `sitecustomize` so
   ad-hoc commands report the canonical path without changing the CLI surface.

## Verified 0.4.2 behavior

- Console script: `nanobot = nanobot.cli.entry:main`; the package also ships
  `nanobot-desktop-tui`.
- `--home <dir>` is a root option (before the subcommand) and selects
  `<dir>/config.json`, `<dir>/workspace`, `<dir>/sessions`, `<dir>/history`.
  There is no environment-variable equivalent in 0.4.2.
- `nanobot.cli.docker_bootstrap.initialize_config(path)` creates a config with
  `gateway.host=0.0.0.0`, websocket enabled on `0.0.0.0:8765`, and a random
  `tokenIssueSecret` (or `NANOBOT_WEB_TOKEN`) when the file is missing.
- `Config()`'s default workspace is `get_default_workspace()`, which returns
  `~/.nanobot/workspace` unless `set_home_path()` was called in that process.
  A bootstrap helper must call
  `set_home_path(Path("/data/config"))` before `initialize_config()`, so the
  saved workspace is the absolute `/data/config/workspace` rather than a
  `~/.nanobot` path.
  Validated against the published 0.4.2 manylinux wheel in a throwaway
  container: the generated config contains
  `"workspace": "/data/config/workspace"`, gateway `0.0.0.0:18790`, and
  websocket `0.0.0.0:8765` with token enforcement.
- The `~/.nanobot -> /data/config` symlink makes default (no `--home`) CLI
  calls resolve to the same config. The bootstrap helper is still used so the
  saved workspace is absolute.
- **As-built shim:** `nanobot status` reports the path from the selected
  instance root, so without extra help it prints
  `/data/home/.nanobot/config.json` (the symlink path) rather than
  `/data/config/config.json`. The image installs a tiny, fail-open
  `sitecustomize.py` in `/app/.venv` that calls
  `set_home_path($NANOBOT_HOME)` at interpreter startup. It affects only the
  nanobot venv, does not change file layout, and lets an explicit `--home`
  override it. This is the only runtime shim; the alternative (a `nanobot`
  wrapper) was rejected because the symlink already handles filesystem
  resolution.

## Privilege model

### Chosen: root entrypoint, then `setpriv`

The container starts as root **only** for the entrypoint's setup phase:

1. `mkdir -p /data/{config,home,pixi,cache}` and cache subdirectories.
2. Safely establish `/data/home/.nanobot -> /data/config`.
3. Fix only mismatched ownership entries in the four persistent trees and the
   symlink, rather than an unconditional `chown -R`:
   `find "$dir" \( ! -uid "$NANOBOT_UID" -o ! -gid "$NANOBOT_GID" \) -exec chown -h "$NANOBOT_UID:$NANOBOT_GID" {} +`
   This keeps large `/data/pixi` and `/data/cache` trees cheap on subsequent
   boots. `find` does not traverse the `.nanobot` symlink by default.
4. Verify `setpriv` can drop privileges; if not, exit nonzero (fail closed).
5. `exec setpriv --reuid=nanobot --regid=nanobot --init-groups "$0" "$@"`.

The re-entered entrypoint runs as `nanobot`, applies
`EXTRA_PIXI_PACKAGES`, bootstraps config if needed, and `exec`s the target
process. The final nanobot process has UID/GID 1000 and empty effective
capabilities.

The setup phase uses `CAP_CHOWN`, `CAP_DAC_OVERRIDE`, `CAP_SETUID`, and
`CAP_SETGID`. `DAC_OVERRIDE` is required because the ownership scan must
traverse directories the dropped user may have created with mode `0700`
(for example `/data/home/.ssh`); without it, root with `cap_drop: ALL` cannot
descend into them. All four capabilities are cleared when `setpriv` drops to
`nanobot`; the final process reports `CapEff: 0000000000000000`.

### Docker exec caveat

Because the image's configured user is `root` (required for the setup phase),
plain `docker exec` also defaults to root. All docs and tests use
`docker exec -u nanobot ...`. Plain `docker exec` can read the config through
the symlink, but it can create root-owned files in `/data`, so it is explicitly
discouraged. This is a Docker constraint, not a design preference; no
per-exec default user exists without violating the root-setup requirement.

### Alternatives rejected

- **Pure non-root image**: cannot chown fresh root-owned named volumes.
- **PUID/PGID runtime remapping**: explicitly dropped in favor of a fixed
  `nanobot` user with build-arg UID/GID.
- **`sudo`/setuid helper**: forbidden by the requirements and incompatible
  with `no-new-privileges`.

## Image design

### Stages

1. `nanobot` stage: `ghcr.io/astral-sh/uv:python3.12-bookworm-slim`.
   - `ENV UV_PYTHON_PREFERENCE=only-system`.
   - `RUN --mount=type=cache,target=/root/.cache/uv`:
     `uv venv --python /usr/local/bin/python3.12 /app/.venv` and
     `uv pip install --python /app/.venv/bin/python "nanobot-ai==${NANOBOT_VERSION}"`.
   - The explicit interpreter pin keeps `/app/.venv/bin/python` on the system
     Python path present in stage 3; it can never point at a uv-managed
     download that disappears between stages.
   - Keep the venv fully in the image layer.
2. `pixi` stage: Debian slim + `curl`/`ca-certificates`.
   - Download the pinned pixi musl tarball for the build architecture, verify
     the release `.sha256`, extract only `pixi` into `/usr/local/bin`.
3. `runtime` stage: `python:3.12-slim-bookworm`.
   - apt: `ca-certificates curl git openssh-client libmagic1 tini tzdata`.
     `bubblewrap` is deliberately not installed: it cannot work under
     `cap_drop: ALL` + `no-new-privileges` without a relaxed seccomp profile.
   - Copy `/app/.venv`, `pixi`, `uv`, `uvx`.
   - `ARG UID=1000`, `ARG GID=1000`; create `nanobot` group/user with home
     `/data/home`; create `/data/{config,home,pixi,cache}` with cache
     subdirs and `/data/config/workspace`.
   - Copy the venv with `COPY --chown=nanobot:nanobot --from=nanobot
     /app/.venv /app/.venv`; never follow it with `RUN chown -R`, which would
     duplicate the whole 445 MB venv in a second layer. Build-time
     `chown -R nanobot:nanobot /data` so image-seeded `.local` subdirectories
     are already owned correctly. The runtime entrypoint still uses only the
     narrow mismatched-owner `find`.
   - Copy `scripts/sitecustomize.py` into the venv's site-packages (see the
     as-built shim note above).
   - `USER root` (the entrypoint drops); `WORKDIR /data/config/workspace`.
   - Copy and `sed -i 's/\r$//'` the entrypoint before `chmod +x`; copy the
     bootstrap helper, healthcheck, and `/etc/nanobot-env.md` (0444).
   - `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]`,
     `CMD ["gateway"]`.
   - `EXPOSE 8765 18790`; `STOPSIGNAL SIGTERM`.

### Environment

```
HOME=/data/home
NANOBOT_HOME=/data/config
NANOBOT_UID=1000
NANOBOT_GID=1000
PIXI_HOME=/data/pixi
PIXI_NO_TELEMETRY=1
PIXI_CACHE_DIR=/data/cache/pixi
XDG_CACHE_HOME=/data/cache
UV_CACHE_DIR=/data/cache/uv
UV_TOOL_DIR=/data/home/.local/share/uv/tools
UV_TOOL_BIN_DIR=/data/home/.local/bin
PIP_CACHE_DIR=/data/cache/pip
PATH=/data/pixi/bin:/data/home/.local/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LANG=C.UTF-8
LC_ALL=C.UTF-8
PYTHONUNBUFFERED=1
PYTHONFAULTHANDLER=1
UV_LINK_MODE=copy
```

`NANOBOT_HOME` is consumed by the image's bootstrap helper and entrypoint; it
is not an upstream nanobot variable.

### Bootstrap helper

`/usr/local/bin/nanobot-bootstrap.py`, run with `/app/.venv/bin/python`:

```python
home = Path(os.environ.get("NANOBOT_HOME", "/data/config"))
set_home_path(home)
initialize_config(home / "config.json")
```

This preserves the absolute `/data/config/workspace` default. It runs only
when `/data/config/config.json` is missing, so existing config is never
rewritten.

### Healthcheck

`/usr/local/bin/healthcheck.py`, invoked by the Dockerfile as:

```
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD ["/app/.venv/bin/python", "-B", "/usr/local/bin/healthcheck.py"]
```

The script does an HTTP GET to
`http://127.0.0.1:${NANOBOT_HEALTH_PORT:-18790}/health` with a 3-second
timeout and exits nonzero on any exception. It uses only the venv Python and
stdlib, not curl. `-B` prevents Docker's root-executed healthcheck from
leaving root-owned `__pycache__` files behind.

### Build polish

- `# syntax=docker/dockerfile:1.7`.
- BuildKit cache mounts for apt lists/archives and the uv build cache.
- `ARG NANOBOT_VERSION=0.4.2`, `ARG PIXI_VERSION=v0.84.2`,
  `ARG UID=1000`, `ARG GID=1000`.
- OCI labels: `org.opencontainers.image.title`, `.description`, `.version`,
  `.licenses`, `.base.name`.
- `.dockerignore` excludes `.git`, `.env`, `data/`, compose files, docs, and
  test artifacts.

## Entrypoint design

### Root phase (`id -u == 0`)

1. Apply defaults for `HOME`, `NANOBOT_HOME`, `PIXI_HOME`, `XDG_CACHE_HOME`,
   and the cache/tool subdirectories; export them.
2. `mkdir -p`:
   - `/data/config`, `/data/config/workspace`
   - `/data/home`, `/data/home/.local/bin`,
     `/data/home/.local/share/uv/tools`
   - `/data/pixi`
   - `/data/cache/pixi`, `/data/cache/uv`, `/data/cache/pip`
3. Establish the symlink with these rules:
   - If `/data/home/.nanobot` is already a symlink to `/data/config`: no-op.
   - If it is a symlink to anywhere else: log and exit nonzero; never retarget
     or delete another target.
   - If it is a mount point: log and exit nonzero; do not touch it.
   - If it is a real empty directory: `rmdir`, then symlink.
   - If it is a real non-empty directory and `/data/config` is empty: copy its
     contents into `/data/config` with `cp -R --preserve=links`, remove the
     source only after a successful copy, then symlink. `cp -a` is avoided
     because preserving metadata on the target root needs `CAP_FOWNER`, which
     is deliberately not granted; the ownership scan fixes ownership after the
     copy. "Empty" ignores an image-seeded empty `/data/config/workspace`
     directory, which Docker copies into every fresh named volume; any real
     config data still forces the legacy-rename path.
   - If it is a real non-empty directory and `/data/config` also has content:
     rename it to `/data/home/.nanobot.legacy.<timestamp>`, leave the data
     intact, then symlink. Log the preserved path.
   - If it is a regular file: rename it to
     `/data/home/.nanobot.legacy.<timestamp>`, then symlink.
4. Fix only mismatched ownership entries in the four trees (including the
   symlink, via `chown -h`) with the `find ... -exec chown -h ... {} +`
   command above. A missing symlink after step 3 is fatal.
5. `setpriv --reuid=nanobot --regid=nanobot --init-groups true`; if it fails,
   print an error and exit 1.
6. `exec setpriv --reuid=nanobot --regid=nanobot --init-groups "$0" "$@"`.

### Unprivileged phase (every start)

1. Re-apply defaults and ensure the four roots and cache/tool subdirectories
   exist (`mkdir -p`). If a required directory is not writable, print one
   actionable error (path, current UID/GID, bind-mount chown guidance) and
   exit 1.
2. If the symlink is missing and the user can create it, create it; otherwise
   fail with the same guidance.
3. Apply `EXTRA_PIXI_PACKAGES`:
   - Split on commas and whitespace; derive the package name from the spec
     (strip an optional `channel::` prefix, then version/build constraints).
   - Skip if the exact package environment exists:
     `[ -d "$PIXI_HOME/envs/<name>" ]` (or an exact `[envs.<name>]` match in
     `$PIXI_HOME/manifests/pixi-global.toml`). No substring matching against
     `pixi global list`.
   - Otherwise run `pixi global install "<spec>"` with no `--environment`
     flag, so each tool gets its own isolated global environment and cannot
     cause cross-tool dependency conflicts.
   - On failure, log a warning with the exact retry command and continue; the
     gateway must still start.
4. Normalize the command:
   - no args -> `gateway`
   - `nanobot ...` -> unchanged
   - known subcommands (`gateway`, `webui`, `agent`, `status`, `onboard`,
     `channels`, `plugins`, `provider`, `trigger`, `update`, `remote`,
     `completion`) or a leading `-...` -> prefix `nanobot`
   - anything else (`bash`, `sh`, `pixi ...`) -> execute directly
5. If the resolved command is `nanobot update`, print a short message saying
   in-container updates are unsupported and the image must be rebuilt with a
   new `NANOBOT_VERSION`, then exit 1.
6. If the resolved command is a `nanobot` invocation whose **subcommand token**
   is `gateway` or `webui` and `/data/config/config.json` is missing, run the
   bootstrap helper. Match the token, not the full argument string, so
   `nanobot gateway --verbose` and `nanobot webui --no-open` still bootstrap.
7. `exec "$@"`.

The root phase never runs pixi or nanobot. The unprivileged phase never calls
`chown`, `sudo`, `apt`, or `apk`.

## Compose design

`compose.yaml` (image-only, no `build:`):

- Service `nanobot`, `image: ${NANOBOT_IMAGE:-nanobot-pixi:0.4.2}`,
  `container_name: nanobot`, `restart: unless-stopped`,
  `stop_grace_period: 30s`.
- `user: "0:0"` to make the root setup phase explicit.
- Four named volumes at the four paths.
- Ports `${NANOBOT_WEB_PORT:-8765}:8765` and
  `127.0.0.1:${NANOBOT_HEALTH_HOST_PORT:-18790}:18790`.
  `NANOBOT_HEALTH_HOST_PORT` is the host side only. The container side stays
  `18790` unless `gateway.port` in `config.json` was actually changed; the
  container-side value is `NANOBOT_HEALTH_PORT` and is what the healthcheck
  reads.
- Environment pass-through: `NANOBOT_WEB_TOKEN`, `EXTRA_PIXI_PACKAGES`,
  `TZ` (default `UTC`), `NANOBOT_HEALTH_PORT` (default `18790`).
- `cap_drop: [ALL]`, `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`,
  `security_opt: [no-new-privileges:true]`.
- No `init: true`; tini is the entrypoint.
- Healthcheck inherited from the Dockerfile.

`compose.build.yaml` adds the `build:` section with `NANOBOT_VERSION`,
`PIXI_VERSION`, `UID`, `GID` args. Local workflow:
`docker compose -f compose.yaml -f compose.build.yaml up -d --build`.

`.env.example` carries `NANOBOT_IMAGE`, `NANOBOT_WEB_TOKEN`,
`EXTRA_PIXI_PACKAGES`, `TZ`, `NANOBOT_HEALTH_HOST_PORT`,
`NANOBOT_HEALTH_PORT`, the WebUI port, and the build-only args. The base
Compose file never builds, so a Portainer stack only pulls the prebuilt
image.

## Bot cheat sheet

`/etc/nanobot-env.md`, mode 0444, covers:

- non-root `nanobot`; no `apt`, `apk`, `sudo`;
- `pixi search <term>`, `pixi info <pkg>`, `pixi global install <pkg>`,
  `pixi global list`;
- what persists: `/data/config`, `/data/home`, `/data/pixi`;
- `/data/cache` is disposable;
- `/app/.venv` and the root filesystem are ephemeral;
- keep work products in `/data/config/workspace` or `/data/home`.

README references it and suggests adding "Read /etc/nanobot-env.md" to the
bot's instructions.

## README contents

- Architecture diagram: image layers (`/app/.venv`, pixi binary, OS) vs the
  four volumes and the symlink.
- Quick start with `.env`, Compose, first WebUI login/password.
- Prebuilt image flow for Portainer; local build overlay.
- Four-volume table, reset/backup matrix, and commands.
- Privilege model: root setup → `setpriv` → nanobot; no sudo; why
  `docker exec -u nanobot` is required.
- pixi discovery/install guidance and the bot cheat sheet.
- CLI/WebUI/gateway commands:
  `docker compose exec -u nanobot nanobot status`,
  `docker compose exec -it -u nanobot nanobot`,
  `docker compose logs -f`, health curl.
- TZ, cache wipe, pixi wipe, home wipe, config backup/restore.
- Image upgrade path (`NANOBOT_VERSION`), not `nanobot update`.

## Verification plan (live Docker)

1. Build succeeds.
2. One-off checks:
   - `id -u`/`id -g` = 1000 in the unprivileged phase;
     `command -v sudo` empty.
   - `HOME`, `PIXI_HOME`, `PIXI_CACHE_DIR`, `XDG_CACHE_HOME`,
     `UV_TOOL_DIR`, `UV_CACHE_DIR`, `PIP_CACHE_DIR` match the table.
   - `nanobot --version`, `pixi --version`, `uv --version`, `tini --version`.
   - `/data/{config,home,pixi,cache}` and cache subdirs exist and are owned by
     1000:1000; `/app/.venv` is writable.
3. Compose up with `EXTRA_PIXI_PACKAGES="jq,ripgrep"`:
   - PID 1 is `tini`; the nanobot process runs as `nanobot` (via `docker top`
     or `/proc`).
   - Fresh/root-owned named volumes are chowned correctly with
     `cap_drop: ALL` + `cap_add: CHOWN, DAC_OVERRIDE, SETUID, SETGID` and
     `no-new-privileges`.
   - Config is created at `/data/config/config.json`; workspace is
     `/data/config/workspace`; logs show the WebUI URL/password or use
     `NANOBOT_WEB_TOKEN`.
   - `/health` is healthy; WebUI listens on 8765; the host-side health port is
     controlled by `NANOBOT_HEALTH_HOST_PORT`, while the healthcheck uses the
     container-side `NANOBOT_HEALTH_PORT`.
   - `jq --version` and `rg --version` work; `pixi global list` shows separate
     `jq` and `ripgrep` environments (no shared `extra` env).
4. Symlink/config resolution:
   - `readlink -f /data/home/.nanobot` = `/data/config`.
   - `docker exec -u nanobot nanobot status` names
     `/data/config/config.json` (even if it exits nonzero for a missing
     provider key).
   - Bootstrap still runs with flags: remove `config.json`, start with
     `gateway --verbose`, and confirm the helper creates the config.
5. Persistence:
   - Markers in `/data/home` and `/data/config/workspace` survive
     `up -d --force-recreate`; jq/ripgrep survive; config/token survive; a
     second start does not reinstall either package.
6. Restricted-directory ownership scan:
   - Create `/data/home/.ssh` with mode `0700` owned by `nanobot:nanobot`;
     restart and `--force-recreate`; startup succeeds cleanly and the
     ownership scan does not fail on the restricted directory.
7. Cache disposal:
   - Delete the cache volume (or its contents); restart; jq/ripgrep and
     `/data/config` still work; cache subdirs are recreated.
8. TZ:
   - `TZ=Europe/Budapest`; `date` shows the expected local offset/zone.
9. Symlink safety:
   - Pre-seed a real non-empty `/data/home/.nanobot` in a fresh volume and
     verify the migration or legacy-rename policy, with no data loss.
10. Fix any failures and repeat before reporting completion.

**Result (2026-11-23):** 126 checks passed, 0 failed. Final image
`nanobot-pixi:smoke` is 1.09 GB; `docker history` shows exactly one 445 MB
venv layer (`COPY --chown=... /app/.venv`) and no duplicate `RUN chown -R`
layer. No test containers, volumes, or networks remained.

## Builder-check resolutions

These were raised by an independent review of the design and settled here so
the implementation plan does not have to guess.

1. **Chat channel / Python extras.** No channel packages are baked into the
   image. `/app/.venv` is writable by `nanobot` precisely so a channel enabled
   at runtime can install its own Python dependency; those installs are
   ephemeral and are replayed on the next container start, using
   `/data/cache/pip` and `/data/cache/uv` for speed. Persistent native/CLI
   tools remain pixi's job. A `NANOBOT_CHANNELS` build arg is out of scope for
   this deliverable.
2. **bubblewrap.** Not installed. It cannot run under `cap_drop: ALL` +
   `no-new-privileges` without a relaxed seccomp profile and extra
   capabilities, which conflicts with the requested security model. README
   notes that a sandboxed exec profile is out of scope for this image.
3. **Architectures.** The Dockerfile selects pixi by build architecture and
   supports `linux/amd64` and `linux/arm64`; live verification is
   `linux/amd64` only on the available host. README shows the buildx command
   for multi-arch builds, but publishing is not part of the work.
4. **Image reference.** `.env.example` defaults to
   `NANOBOT_IMAGE=nanobot-pixi:0.4.2`; Portainer users replace it with their
   registry path. No registry credentials, CI, or push are in scope. The base
   Compose file never builds.
5. **Upgrades.** Upgrading is a manual, backup-gated image rebuild. The
   entrypoint rejects an in-container `nanobot update` with a message to
   rebuild with a new `NANOBOT_VERSION`. A pixi version bump keeps
   `/data/pixi`; if a new pixi cannot read old global envs, the documented fix
   is to wipe `/data/pixi` and let `EXTRA_PIXI_PACKAGES` reinstall. No
   automatic config migration or version check is added.
6. **Host support.** Named volumes are the verified path on Linux and Docker
   Desktop. The bind-mount recipe is Linux-only because host ownership is the
   operator's responsibility; there is no non-root workaround for Docker
   Desktop bind mounts, and the README says so.

## Risks / notes

- **Docker exec user**: the image user is root for the setup phase; plain
  `docker exec` is root. Use `-u nanobot`. Document prominently.
- **Named volume seeding**: Docker initializes volumes from image ownership;
  the entrypoint also chowns, covering volumes created root-owned outside
  Compose.
- **Bind mounts**: host ownership is not fixed by the image. Use named volumes
  or chown the host dirs to the build UID/GID; the entrypoint fails loudly.
- **Ownership scan cost**: every start walks the four trees and chowns only
  entries whose UID/GID differ; this is much cheaper than `chown -R` on large
  pixi/home trees but is still a full directory walk.
- **Bootstrap token**: `NANOBOT_WEB_TOKEN` only applies when the config is
  first created. Changing it later requires editing/removing `config.json`.
- **Channel/Python deps**: installed into `/app/.venv` are ephemeral; caches
  in `/data/cache` speed reinstall. Persistent native tools belong in pixi.
- **Healthcheck**: assumes the gateway health port is 18790. Change
  `NANOBOT_HEALTH_PORT` only when `gateway.port` in `config.json` changes;
  `NANOBOT_HEALTH_HOST_PORT` only moves the host-side published port.
- **`nanobot update`**: unsupported in-container; rebuild with a new
  `NANOBOT_VERSION`.

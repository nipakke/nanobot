# nanobot + pixi Docker Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and live-verify a Docker image that runs `nanobot-ai==0.4.2` as non-root `nanobot`, with pixi-managed tools and four independent persistent trees.

**Architecture:** Three-stage build (uv-built `/app/.venv`, downloaded pixi binary, Debian runtime). A tini-wrapped root entrypoint creates/chowns four `/data` trees and the `~/.nanobot -> /data/config` symlink, then `setpriv` drops to `nanobot` before anything else runs. Compose uses four named volumes and a minimal capability set; a separate build overlay keeps the base stack pull-only for Portainer.

**Tech Stack:** Docker/BuildKit, Docker Compose, Debian bookworm-slim, Python 3.12, uv, pixi, tini, nanobot 0.4.2.

**Spec:** `docs/superpowers/specs/2026-11-23-nanobot-pixi-docker-design.md`

## Global Constraints

- `nanobot-ai==0.4.2`; pixi `v0.84.2`; Python 3.12; Debian bookworm; no Alpine.
- Four persistent paths: `/data/config`, `/data/home`, `/data/pixi`, `/data/cache`.
- `HOME=/data/home`; `PIXI_HOME=/data/pixi`; `XDG_CACHE_HOME=/data/cache`; `PIXI_CACHE_DIR=/data/cache/pixi`; `UV_CACHE_DIR=/data/cache/uv`; `PIP_CACHE_DIR=/data/cache/pip`; `UV_TOOL_DIR=/data/home/.local/share/uv/tools`; `UV_TOOL_BIN_DIR=/data/home/.local/bin`.
- `/data/home/.nanobot` is a symlink to `/data/config`; never clobber a wrong-target symlink, a mount point, or non-empty user data.
- Entrypoint starts as root only to create/chown/symlink, then `setpriv --reuid=nanobot --regid=nanobot --init-groups`; fail closed if the drop fails.
- Capabilities: `CHOWN`, `DAC_OVERRIDE`, `SETUID`, `SETGID`; `cap_drop: [ALL]`; `no-new-privileges:true`.
- No `sudo`, no `bubblewrap`, no runtime `apt`/`apk` tool installs.
- `/app/.venv` stays in the image layer, is owned by `nanobot`, and is never mounted over.
- Host health port: `NANOBOT_HEALTH_HOST_PORT`; container health port and healthcheck: `NANOBOT_HEALTH_PORT` (default 18790).
- `PIXI_NO_TELEMETRY=1`; `LANG=C.UTF-8`; `LC_ALL=C.UTF-8`; `PYTHONUNBUFFERED=1`; `PYTHONFAULTHANDLER=1`.
- Image default CMD `gateway`; ENTRYPOINT `["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]`.
- No git repository is present; do not initialize one, commit, push, or publish.

## File Structure

- `Dockerfile` — three build stages, runtime env, user, labels, healthcheck.
- `entrypoint.sh` — root setup phase, setpriv drop, symlink policy, extras, bootstrap, exec.
- `scripts/nanobot-bootstrap.py` — `set_home_path()` + `initialize_config()`.
- `scripts/healthcheck.py` — stdlib HTTP probe on the gateway health port.
- `etc/nanobot-env.md` — read-only bot cheat sheet.
- `compose.yaml` — image-only stack with four named volumes.
- `compose.build.yaml` — local build overlay and build args.
- `.env.example` — image, token, extras, TZ, ports, build args.
- `.dockerignore` — exclude non-build inputs.
- `scripts/smoke-test.sh` — acceptance suite (all checks below).
- `README.md` — architecture, quick start, permissions, pixi/bot guidance, reset/backup, verification.

## Review Focus

1. Root-owned named volume plus a `0700` `/data/home/.ssh` owned by `nanobot`: startup must still traverse and succeed (`DAC_OVERRIDE`).
2. Pre-existing real `/data/home/.nanobot` with content: migrate when `/data/config` is empty, preserve as legacy when both have data, fail closed on wrong-target symlinks/mount points.
3. Missing config plus `gateway --verbose` / `webui --no-open`: bootstrap must trigger by subcommand token and save workspace `/data/config/workspace`.
4. `EXTRA_PIXI_PACKAGES` with two tools: isolated per-package envs, exact env detection, no reinstall after force-recreate, cache wipe does not break tools.
5. Docker exec defaults to root: docs and checks use `docker exec -u nanobot`; host/container health ports remain distinct.

---

### Task 1: Acceptance smoke test

**Files:**
- Create: `scripts/smoke-test.sh`

**Interfaces:**
- Consumes: image `nanobot-pixi:smoke`, Compose services/volumes from later tasks, unique project name.
- Produces: a single command that exits 0 only when every assertion A1–A20 passes.

- [ ] **Step 1: Write the failing acceptance script**

Create `scripts/smoke-test.sh` with `set -euo pipefail`, a unique project name
(`nanobot-smoke-$$`), a cleanup trap (`docker compose -p "$PROJECT" -f
compose.yaml down -v --remove-orphans` plus removal of any pre-created
volumes), and assertions A1–A20 below. Use `docker compose up -d --wait` and
`docker inspect` for health; use `docker exec -u nanobot` for user commands and
`docker exec -u 0` only for inspection.

Assertions:
- A1 build succeeds: `docker build -t nanobot-pixi:smoke .`
- A2 unprivileged `id -u`/`id -g` = 1000; `command -v sudo` empty.
- A3 env values: `HOME`, `NANOBOT_HOME`, `PIXI_HOME`, `PIXI_CACHE_DIR`,
  `XDG_CACHE_HOME`, `UV_CACHE_DIR`, `UV_TOOL_DIR`, `UV_TOOL_BIN_DIR`,
  `PIP_CACHE_DIR`; PATH begins `/data/pixi/bin:`.
- A4 `nanobot --version`, `pixi --version`, `uv --version`, `tini --version`
  succeed.
- A5 `/data/{config,home,pixi,cache}` and `/data/cache/{pixi,uv,pip}` exist,
  owned `1000:1000`; `/app/.venv` is writable by `nanobot`; `bwrap` absent.
- A6 Pre-create the four named volumes with `docker volume create` (root-owned)
  before Compose up; startup must fix ownership without errors.
- A7 PID 1 is `tini`; `docker top` shows the nanobot process user as `nanobot`.
- A8 `/data/home/.nanobot` resolves to `/data/config`.
- A9 `docker exec -u nanobot nanobot status` output contains
  `/data/config/config.json` (allow a nonzero exit for a missing provider key).
- A10 `config.json` has `agents.defaults.workspace=/data/config/workspace`,
  `gateway.host=0.0.0.0`, websocket host `0.0.0.0` port `8765`.
- A11 `EXTRA_PIXI_PACKAGES=jq,ripgrep`: both commands work;
  `/data/pixi/envs/jq` and `/data/pixi/envs/ripgrep` exist; no shared `extra`.
- A12 A second start logs that both packages are already present and does not
  fetch them again.
- A13 Create `/data/home/.ssh` mode `0700` owned `nanobot:nanobot`; `restart`
  and `up -d --force-recreate` both succeed.
- A14 Markers in `/data/home` and `/data/config/workspace` survive
  force-recreate; config and WebUI token survive.
- A15 Delete `/data/cache/pixi`, `/data/cache/uv`, `/data/cache/pip`; restart;
  jq/ripgrep and config still work and cache dirs are recreated.
- A16 `TZ=Europe/Budapest`; `date +%Z` is `CET` or `CEST`.
- A17 Docker health is `healthy`; host port `NANOBOT_HEALTH_HOST_PORT=18791`
  serves `/health`; container healthcheck uses `NANOBOT_HEALTH_PORT=18790`.
- A18 Delete `config.json`; start with `gateway --verbose`; config is recreated.
- A19 Pre-seed a non-empty `/data/home/.nanobot` in a fresh volume with an empty
  `/data/config`; its file is migrated to `/data/config` without loss, and a
  wrong-target symlink fails closed without being retargeted.
- A20 `nanobot update` is rejected with rebuild guidance; `uv tool install
  ruff` writes `/data/cache/uv` and `/data/home/.local/share/uv/tools/ruff`,
  and `/etc/nanobot-env.md` is mode 0444 with the no-apt/pixi rules.

- [ ] **Step 2: Run the script and confirm it fails for the expected reason**

Run: `bash scripts/smoke-test.sh`
Expected: FAIL before any assertion because `Dockerfile` does not exist.

### Task 2: Image and entrypoint

**Files:**
- Create: `Dockerfile`, `entrypoint.sh`, `scripts/nanobot-bootstrap.py`,
  `scripts/healthcheck.py`, `etc/nanobot-env.md`, `.dockerignore`.

**Interfaces:**
- Produces: image exposing `/app/.venv/bin/nanobot`, `/usr/local/bin/pixi`,
  `/usr/local/bin/uv`, `/usr/local/bin/uvx`, `/usr/bin/tini`; env and paths
  from the Global Constraints.
- Produces: entrypoint root/unprivileged phases and symlink policy from the
  spec.

- [ ] **Step 1: Write the Dockerfile**

Use `# syntax=docker/dockerfile:1.7`. Stage 1 is
`ghcr.io/astral-sh/uv:python3.12-bookworm-slim` with
`UV_PYTHON_PREFERENCE=only-system`, `UV_LINK_MODE=copy`,
`UV_COMPILE_BYTECODE=1`, `RUN --mount=type=cache,target=/root/.cache/uv`
`uv venv --python /usr/local/bin/python3.12 /app/.venv` and
`uv pip install --python /app/.venv/bin/python "nanobot-ai==${NANOBOT_VERSION}"`.
Stage 2 downloads and SHA-256-verifies the pinned pixi musl tarball for
`uname -m` and installs only `pixi`. Stage 3 is
`python:3.12-slim-bookworm`; apt-install `ca-certificates curl git
openssh-client libmagic1 tini tzdata` with apt cache mounts; copy the venv,
pixi, uv, uvx; create user `nanobot` from `ARG UID=1000`/`ARG GID=1000`; create
and chown `/data` trees and `/app/.venv`; set `ENV NANOBOT_UID`,
`NANOBOT_GID`, the rest of the environment, and OCI labels; copy entrypoint
with `sed -i 's/\r$//'` then `chmod +x`; copy support scripts; `USER root`;
`WORKDIR /data/config/workspace`; `EXPOSE 8765 18790`;
`HEALTHCHECK ... /app/.venv/bin/python -B /usr/local/bin/healthcheck.py`;
`ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]`;
`CMD ["gateway"]`.

- [ ] **Step 2: Write the entrypoint**

Implement the root phase (mkdir, safe symlink policy, mismatched-owner `find`
with `-exec chown -h`, setpriv test, fail closed, re-exec) and the
unprivileged phase (mkdir/writability checks, symlink repair, extras, command
normalization, reject `nanobot update`, bootstrap by subcommand token, exec).
Never call `chown`, `apt`, or `apk` after the drop.

- [ ] **Step 3: Write the support scripts and cheat sheet**

`nanobot-bootstrap.py` must call `set_home_path(Path(NANOBOT_HOME))` before
`initialize_config(NANOBOT_HOME/config.json)`. `healthcheck.py` must HTTP GET
`http://127.0.0.1:${NANOBOT_HEALTH_PORT:-18790}/health` with a 3s timeout and
exit nonzero on exception. `etc/nanobot-env.md` contains the non-root/no-apt/
pixi/persistence/ephemeral-root rules from the spec, mode 0444.

- [ ] **Step 4: Build and run static checks**

Run: `docker build -t nanobot-pixi:smoke .`
Expected: build succeeds; `pixi --version` prints `0.84.2`; image has no
`bwrap`; `/etc/nanobot-env.md` is 0444; `/app/.venv` is writable by UID 1000;
`/data` dirs are owned 1000:1000 in the image.

### Task 3: Compose and environment

**Files:**
- Create: `compose.yaml`, `compose.build.yaml`, `.env.example`.

**Interfaces:**
- Produces: service `nanobot` with four named volumes, image
  `${NANOBOT_IMAGE:-nanobot-pixi:0.4.2}`, `user: "0:0"`, cap drop/add,
  `no-new-privileges`, port mappings, env pass-through, healthcheck inherited.
- Produces: build overlay with `NANOBOT_VERSION`, `PIXI_VERSION`, `UID`, `GID`.

- [ ] **Step 1: Write `compose.yaml`**

Use the exact caps `[CHOWN, DAC_OVERRIDE, SETUID, SETGID]`; host health mapping
`127.0.0.1:${NANOBOT_HEALTH_HOST_PORT:-18790}:18790`; container
`NANOBOT_HEALTH_PORT=18790`; WebUI `${NANOBOT_WEB_PORT:-8765}:8765`; volumes
`nanobot_config`, `nanobot_home`, `nanobot_pixi`, `nanobot_cache`; no
`build:`; no `init: true`; `restart: unless-stopped`; `stop_grace_period: 30s`.

- [ ] **Step 2: Write the build overlay and env example**

`compose.build.yaml` adds `build.context: .` and args
`NANOBOT_VERSION=0.4.2`, `PIXI_VERSION=v0.84.2`, `UID`, `GID`.
`.env.example` documents `NANOBOT_IMAGE`, token, extras, TZ, WebUI port,
`NANOBOT_HEALTH_HOST_PORT`, `NANOBOT_HEALTH_PORT`, and build args.

- [ ] **Step 3: Validate Compose**

Run: `docker compose -f compose.yaml -f compose.build.yaml config -q`.
Expected: exit 0 with no errors.

### Task 4: README and bot guidance

**Files:**
- Create: `README.md`.

**Interfaces:**
- Consumes: all previous paths, env names, caps, reset matrix.
- Produces: operator and bot instructions; references `/etc/nanobot-env.md`.

- [ ] **Step 1: Write the README**

Cover architecture, four-volume table, build/Portainer flow, privilege model
and `docker exec -u nanobot`, pixi discovery/install and persistence, the bot
cheat sheet, CLI/WebUI/gateway commands, TZ, reset/backup matrix, upgrade
policy, and the live verification commands.

- [ ] **Step 2: Check coverage**

Confirm every README section maps to the spec; no `bubblewrap`, no `sudo`, no
shared `extra` env, no plain `docker exec` recommendation.

### Task 5: Live verification and fixes

**Files:**
- Modify as needed: any file from Tasks 1–4.
- Test: `scripts/smoke-test.sh`.

- [ ] **Step 1: Run the full acceptance suite**

Run: `bash scripts/smoke-test.sh`
Expected: all A1–A20 pass. Iterate on failures; do not weaken assertions
without recording why.

- [ ] **Step 2: Capture evidence**

Record: Docker/Compose versions, build output tail, image size, `docker top`,
health status, `id`/env output, symlink resolution, config assertions,
`pixi global list`/env dirs, `.ssh` restart result, force-recreate result,
cache-wipe result, TZ output, bootstrap-with-flags result, symlink-safety
result, `uv` tool/cache result.

- [ ] **Step 3: Clean up test resources**

`docker compose -p "$PROJECT" down -v --remove-orphans`; remove any
pre-created volumes and temporary files. Leave no `nanobot-smoke-*` volumes.

- [ ] **Step 4: Report**

Report exact commands and observed output. State any deviation from the spec
and why. Do not claim a check that did not run.

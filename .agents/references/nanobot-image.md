# nanobot image — durable facts

Sources: `README.md`, `docs/superpowers/specs/2026-11-23-nanobot-pixi-docker-design.md`, `Dockerfile`, `entrypoint.sh`, `compose*.yaml`, `scripts/smoke-test.sh`.

## Image

- Debian `bookworm-slim`; glibc is required, so no Alpine. `nanobot-ai==0.4.2` lives in `/app/.venv` (image layer, ephemeral, owned by `nanobot`); the pixi binary is baked in.
- The default image omits the ~123 MiB `nanobot/tui/bin/nanobot-tui-linux-x64` from the builder stage, so no whiteout and no final-image layer carries it. The launcher downloads the checksum-verified release asset to `/data/config/bin/tui/<version>` on first TUI use; `NANOBOT_TUI_NO_DOWNLOAD=1` forces the documented `TuiUnavailableError`. `BUNDLE_TUI=1` keeps the binary for offline/air-gapped builds.
- No `.pyc` is baked. `PYTHONPYCACHEPREFIX=/data/cache/pycache` compiles imported modules on first use into the disposable cache tree; recreates reuse them. Healthcheck still runs `-B`.
- Homebrew source is pinned to release 7.0.16 / commit `7ef183d10e7d6e5620d7124b744b1dfbf69fc108` (`BREW_VERSION`, `BREW_COMMIT`), verified at build time. `docs`, `manpages`, `completions` and `.github` are pruned; `.git` is kept so `brew --version` reports the concrete release.
- pixi is the only supported way to install runtime native/CLI tools. No runtime `apt`/`apk`, no `sudo`, no setuid helpers.
- Root exists only for setup (`/data` trees and ownership fixes), then `exec setpriv --reuid=nanobot --regid=nanobot --init-groups`.
- Compose: `cap_drop: [ALL]`, `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`, `security_opt: [no-new-privileges:true]`. All caps are cleared after the drop; `DAC_OVERRIDE` lets the ownership scan enter `0700` dirs such as `/data/home/.ssh`.
- The image user is root, so every `docker exec` needs `-u nanobot`; a plain exec can create root-owned files in `/data`. Docker constraint, not a preference.
- In-container `nanobot update` is rejected by design. Upgrade with a `/data/config` backup and an image rebuild: set both `NANOBOT_VERSION` (package) and `NANOBOT_IMAGE` (tag Compose runs).
- Shell scripts (`*.sh`) stay LF; never commit CRLF.

## Persistence

- Five trees: `/data/config` (`NANOBOT_HOME`: config, sessions, memory, workspace, downloaded TUI bundles), `/data/home` (`HOME`, uv tools, npm globals, `~/.local/bin`), `/data/pixi` (`PIXI_HOME`), `/data/brew` (`HOMEBREW_PREFIX`), `/data/cache` (100% disposable, including `pycache`).
- `/data/brew` is always the `nanobot_brew` named volume, in both modes. Never point it at `./data`, where Homebrew's write churn has destabilised the Docker engine (see `.agents/lessons/rules.md`).
- `compose.bind.yaml` maps config/home/pixi/cache to binds under `./data`; brew stays a volume. `docker compose -f compose.yaml -f compose.bind.yaml config` shows four binds and one volume at `/data/brew`.
- The root phase creates `/data/home/.nanobot -> /data/config`; `/data/home/.nanobot` symlinks to `/data/config` and is never a real directory.
- The symlink is load-bearing, not cosmetic: nanobot 0.4.2 builds its update/data-access locks, bun tool cache, QQ media and gateway default config path from `Path.home()/".nanobot"` and ignores `set_home_path()`. Without the symlink those land in `/data/home` (verified: `updates/data-locks`), splitting state across trees. Never remove it without patching those call sites.
- Wiping `/data/cache` must never break installed tools or config.
- Never mount a volume over `/app/.venv`; it changes only with `NANOBOT_VERSION` or the image tag.
- `NANOBOT_HOME` is an image-level helper, not upstream nanobot 0.4.2 (no env equivalent to `--home`). The venv `sitecustomize.py` shim and the `/data/home/.nanobot -> /data/config` symlink together make resolution consistent: `nanobot status` names `/data/config/config.json` and filesystem-based resolution lands in `/data/config`.
- Health: container-side `NANOBOT_HEALTH_PORT` (default 18790) is what the healthcheck reads; `NANOBOT_HEALTH_HOST_PORT` moves only the published host port.
- One container per data folder: two gateways on the same `./data` corrupt sessions and race on the workspace `.git` (`GitStoreError: Git store init failed`, dulwich `FileExistsError`).

## Runtime installation

- `EXTRA_PIXI_PACKAGES` installs each package into its own pixi global env (`/data/pixi/envs/<pkg>`) at startup; failures warn and do not block the gateway.
- `NANOBOT_CHANNELS` pre-installs channel Python dependencies into `/app/.venv` at startup, replayed from `/data/cache/uv` on recreate. Entrypoint-only and non-fatal.
- `npm_config_prefix=/data/home/.local` (also recorded in `~/.npmrc`). `$HOME/.local/bin/brew` symlinks to the `nanobot-brew` wrapper (`scripts/brew-wrapper.sh`), restoring the `HOMEBREW_*` defaults the WebUI app runner's stripped env drops.
- `PATH`: `/data/pixi/bin`, `/data/home/.local/bin`, `/data/brew/bin`, `/app/.venv/bin`.
- nanobot's agent exec tool starts with a clean env: `_build_env` omits `PATH` and the image's cache/runtime vars, so container defaults do not reach the agent. Bootstrap sets `tools.exec.pathPrepend` to the four image tool dirs and forwards `PIXI_HOME`, `PIXI_CACHE_DIR`, `PIXI_NO_TELEMETRY`, `XDG_CACHE_HOME`, `UV_CACHE_DIR`, `UV_LINK_MODE`, `PIP_CACHE_DIR`, `PYTHONPYCACHEPREFIX`, `NANOBOT_HOME`, and `TZ` in `tools.exec.allowedEnvKeys`; without them, `pixi global list` reports no environments and tool caches leak into `/data/home`. Existing configs created before this need both fields updated.
- `/usr/bin/unzip` is baked in for zip-based casks. Without it, Homebrew's ZIP strategy calls `Formula["unzip"]` inside its Landlock sandbox, which tries to write the formula API cache and fails with `EACCES` on a cold cache at `api.rb:288` (seen with `brew install --cask 1password-cli`).

## Commands

```sh
# Live stack, bind mode (config/home/pixi/cache in ./data, brew on nanobot_brew)
docker compose -f compose.yaml -f compose.bind.yaml up -d

# Named-volume stack / local build
docker compose up -d
docker compose -f compose.yaml -f compose.build.yaml up -d --build

# Acceptance suite A1-A22: builds nanobot-pixi:smoke, unique project,
# container, and host ports; cleans up only its own resources
bash scripts/smoke-test.sh
NANOBOT_SMOKE_WEB_PORT=<port> NANOBOT_SMOKE_HEALTH_PORT=<port> bash scripts/smoke-test.sh

# Validate the Compose overlay chain
docker compose -f compose.yaml -f compose.bind.yaml config -q
```

The suite defaults to host ports 18766 (web) and 18791 (health); both are overridable with `NANOBOT_SMOKE_WEB_PORT` / `NANOBOT_SMOKE_HEALTH_PORT`. On Windows hosts whose excluded port ranges cover the defaults, Docker Desktop fails with `forwards/expose ... 500` and an access-denied bind, so pick free ports.

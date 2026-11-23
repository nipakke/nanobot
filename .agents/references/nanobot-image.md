# nanobot image — durable facts

Sources: `README.md`, `docs/*.md`, `Dockerfile`, `entrypoint.sh`, `compose*.yml`, `scripts/smoke-test.sh`.

## Image

- Debian `bookworm-slim`; glibc is required, so no Alpine. `nanobot-ai` (version pinned in `Dockerfile`) lives in `/app/.venv` (image layer, ephemeral, owned by `nanobot`); the pixi binary is baked in.
- The default image omits the ~123 MiB `nanobot/tui/bin/nanobot-tui-linux-x64` from the builder stage, so no whiteout and no final-image layer carries it. The launcher downloads the checksum-verified release asset to `/data/config/bin/tui/<version>` on first TUI use; `NANOBOT_TUI_NO_DOWNLOAD=1` forces the documented `TuiUnavailableError`. `BUNDLE_TUI=1` keeps the binary for offline/air-gapped builds.
- No `.pyc` is baked. `PYTHONPYCACHEPREFIX=/data/cache/pycache` compiles imported modules on first use into the disposable cache tree; recreates reuse them. Healthcheck runs the root-owned system Python with `-I -B` and drops to `nanobot` before probing.
- Homebrew source is pinned to a release tag and commit (`BREW_VERSION`, `BREW_COMMIT` in `Dockerfile`), verified at build time. `docs`, `manpages`, `completions` and `.github` are pruned; `.git` is kept so `brew --version` reports the concrete release.
- pixi is the only supported way to install runtime native/CLI tools. No runtime `apt`/`apk`, no `sudo`, no setuid helpers.
- Root exists only for setup (`/data` trees and ownership fixes), then `exec setpriv --reuid=nanobot --regid=nanobot --init-groups`.
- Compose: `cap_drop: [ALL]`, `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`, `security_opt: [no-new-privileges:true]`. All caps are cleared after the drop; `DAC_OVERRIDE` lets the ownership scan enter `0700` dirs such as `/data/home/.ssh`.
- The image user is root, so every `docker exec` needs `-u nanobot`; a plain exec can create root-owned files in `/data`. Docker constraint, not a preference.
- In-container `nanobot update` is rejected by design. Upgrade with a `/data/config` backup by pulling the new published tag (or rebuilding locally with `NANOBOT_VERSION` and `NANOBOT_BUILD_IMAGE`).
- Shell scripts (`*.sh`) stay LF; never commit CRLF.

## Persistence

- Five trees under `/data`: `/data/config` (`NANOBOT_HOME`: config, sessions, memory, workspace, downloaded TUI bundles), `/data/home` (`HOME`, uv tools, npm globals, `~/.local/bin`), `/data/pixi` (`PIXI_HOME`), `/data/brew` (`HOMEBREW_PREFIX`), `/data/cache` (100% disposable, including `pycache`).
- `compose.yml` uses bind mounts (`./data:/data` by default, with the 5 separate bind mounts commented out) and declares `healthcheck:`. `Dockerfile` stores the baked Homebrew tree at `/usr/local/share/nanobot-brew-seed` (same layer, no duplication) and `entrypoint.sh` seeds `/data/brew` on first start when `/data/brew/bin/brew` is absent, so a single empty host bind mount (e.g. `/data/nanobot:/data`) works out of the box without network. On Windows/Docker Desktop 9p binds, heavy brew write churn can still destabilise the engine (see `.agents/lessons/rules.md`), so `scripts/smoke-compose.yml` overrides `volumes:` with isolated named volumes for smoke tests.
- The root phase creates `/data/home/.nanobot -> /data/config`; `/data/home/.nanobot` symlinks to `/data/config` and is never a real directory. Symlink setup never clobbers data: a pre-existing directory migrates into an empty `/data/config`, is preserved as `.nanobot.legacy.<timestamp>` if both hold data, and a wrong-target symlink or mount point fails closed.
- The symlink is load-bearing, not cosmetic: upstream nanobot builds its update/data-access locks, bun tool cache, QQ media and gateway default config path from `Path.home()/".nanobot"` and ignores `set_home_path()`. Without the symlink those land in `/data/home` (verified: `updates/data-locks`), splitting state across trees. Never remove it without patching those call sites.
- Wiping `/data/cache` must never break installed tools or config.
- Never mount a volume over `/app/.venv`; it changes only with `NANOBOT_VERSION` or the image tag.
- `NANOBOT_HOME` is an image-level helper, not an upstream nanobot variable (no env equivalent to `--home`). The venv `sitecustomize.py` shim and the `/data/home/.nanobot -> /data/config` symlink together make resolution consistent: `nanobot status` names `/data/config/config.json` and filesystem-based resolution lands in `/data/config`.
- Ports: container ports are fixed (`8765` WebUI, `18790` healthcheck); `compose.yml` publishes `8765:8765` and `127.0.0.1:18790:18790` directly (`smoke-compose.yml` overrides host ports for tests).
- One container per data folder: two gateways on the same `./data` corrupt sessions and race on the workspace `.git` (`GitStoreError: Git store init failed`, dulwich `FileExistsError`).

## Runtime installation

- `EXTRA_PIXI_PACKAGES` installs each package into its own pixi global env (`/data/pixi/envs/<pkg>`) at startup; failures warn and do not block the gateway.
- `NANOBOT_CHANNELS` pre-installs channel Python dependencies into `/app/.venv` at startup, replayed from `/data/cache/uv` on recreate. Entrypoint-only and non-fatal.
- `npm_config_prefix=/data/home/.local` (also recorded in `~/.npmrc`). `$HOME/.local/bin/brew` symlinks to the `nanobot-brew` wrapper (`scripts/brew-wrapper.sh`), restoring the `HOMEBREW_*` defaults the WebUI app runner's stripped env drops.
- `PATH`: `/data/pixi/bin`, `/data/home/.local/bin`, `/data/brew/bin`, `/app/.venv/bin`.
- nanobot's agent exec tool starts with a clean env: `_build_env` omits `PATH` and the image's cache/runtime vars, so container defaults do not reach the agent. Bootstrap sets `tools.exec.pathPrepend` to the four image tool dirs and forwards `PIXI_HOME`, `PIXI_CACHE_DIR`, `PIXI_NO_TELEMETRY`, `XDG_CACHE_HOME`, `UV_CACHE_DIR`, `UV_LINK_MODE`, `PIP_CACHE_DIR`, `PYTHONPYCACHEPREFIX`, `NANOBOT_HOME`, and `TZ` in `tools.exec.allowedEnvKeys`; without them, `pixi global list` reports no environments and tool caches leak into `/data/home`. Existing configs created before this need both fields updated.
- `/usr/bin/unzip` is baked in for zip-based casks. Without it, Homebrew's ZIP strategy calls `Formula["unzip"]` inside its Landlock sandbox, which tries to write the formula API cache and fails with `EACCES` on a cold cache at `api.rb:288` (seen with `brew install --cask 1password-cli`).

## Publishing and updates

- `Dockerfile` is the single source of truth for version pins (`NANOBOT_VERSION`, `PIXI_VERSION`, `BREW_VERSION` + `BREW_COMMIT`, and digest-pinned `FROM` lines). `compose.build.yml` passes pin args through only when set in env/`.env`; `compose.yml` defaults to `nipakke/nanobot:latest` while `compose.build.yml` tags `nanobot-pixi:local`.
- `renovate.json`: stable releases only, 2-day `minimumReleaseAge`. Every `nanobot-ai` release (majors included) opens a PR immediately and auto-merges on green `test`; base-image digests, pixi, Homebrew, and GitHub Actions (minor/patch/digest) batch into one monthly auto-merged PR on the 1st; majors of non-nanobot dependencies wait for approval.
- Two separate workflows keep PRs isolated from registry secrets on a public repo: `.github/workflows/test.yml` (`pull_request` only, required check, zero secrets) and `.github/workflows/publish.yml` (`push` to `main` on image-file paths or `workflow_dispatch`; builds, runs the smoke test suite via `NANOBOT_SMOKE_SKIP_BUILD=1`, tags `latest`, `<version>`, and immutable `<version>-<YYYYMMDD>-<shortsha>`, then pushes that exact tested image).

## Commands

```sh
# Named-volume stack / local build
docker compose up -d
docker compose -f compose.yml -f compose.build.yml up -d --build

# Smoke test suite: builds nanobot-pixi:smoke, unique project,
# container, and host ports; cleans up only its own resources
bash scripts/smoke-test.sh
NANOBOT_SMOKE_WEB_PORT=<port> NANOBOT_SMOKE_HEALTH_PORT=<port> bash scripts/smoke-test.sh

# Validate Compose files
docker compose -f compose.yml config -q
docker compose -f compose.yml -f compose.build.yml config -q
```

The suite defaults to host ports 18766 (web) and 18791 (health); both are overridable with `NANOBOT_SMOKE_WEB_PORT` / `NANOBOT_SMOKE_HEALTH_PORT`. On Windows hosts whose excluded port ranges cover the defaults, Docker Desktop fails with `forwards/expose ... 500` and an access-denied bind, so pick free ports.

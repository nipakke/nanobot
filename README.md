# nanobot + pixi in Docker

Run `nanobot-ai` (the latest stable release, tracked automatically; see
[Published image and updates](#published-image-and-updates)) in a reproducible
Debian container with:

- pixi as the supported way for the bot to install native/CLI tools at runtime;
- Homebrew baked into the image at `/data/brew`, on its own persistent volume,
  so WebUI Apps installed with `brew` survive recreates and image upgrades;
- `npm` global installs redirected to `~/.local/bin` (on `PATH`), with the npm
  cache in the persistent home tree;
- a dedicated non-root `nanobot` user (UID/GID 1000) with no `sudo`;
- five independent persistent trees, so config, home, tools, brew, and caches
  can be reset separately;
- an image-baked, ephemeral `/app/.venv` that changes only with the image tag
  (writable by `nanobot` for channel dependency installs, but never mounted);
- no `.pyc` baked into the image and no bundled native TUI binary by default:
  bytecode compiles on first use into the disposable cache, and the TUI
  downloads into `/data/config` when first needed;
- optional channel Python dependencies installed at startup from
  `NANOBOT_CHANNELS`, replayed from the persistent cache on recreate;
- a marked environment-rules block maintained in the workspace `AGENTS.md`, the
  file the agent actually reads.

The image starts as root only for the entrypoint setup phase, then drops to
`nanobot` with `setpriv`. See [Privilege model](#privilege-model).

## Architecture

```
image layers (ephemeral)                 named volumes (persistent)
┌──────────────────────────────┐         ┌──────────────────────────────┐
│ /app/.venv   nanobot-ai      │         │ nanobot_config -> /data/config│
│ /usr/local/bin/pixi          │         │   config.json, sessions,      │
│ /usr/local/bin/uv, uvx       │         │   memory, workspace           │
│ OS packages, tini, health    │         ├──────────────────────────────┤
│ Homebrew install (seed only) │         │ nanobot_home -> /data/home    │
└──────────────────────────────┘         │   HOME, dotfiles, uv tools,   │
                                         │   ~/.local/bin, ~/.npm        │
/data/home/.nanobot -> /data/config      ├──────────────────────────────┤
  (symlink, created at startup)          │ nanobot_pixi -> /data/pixi    │
                                         │   pixi global envs + binaries │
                                         ├──────────────────────────────┤
                                         │ nanobot_brew -> /data/brew    │
                                         │   Homebrew repo, Cellar       │
                                         ├──────────────────────────────┤
                                         │ nanobot_cache -> /data/cache  │
                                         │   pixi/uv/pip/brew caches     │
                                         └──────────────────────────────┘
```

The startup order is:

1. root: create `/data/{config,home,pixi,brew,cache}`, establish the
   `/data/home/.nanobot -> /data/config` symlink, fix mismatched ownership;
2. `setpriv` drops to `nanobot`;
3. `nanobot` phase: record the npm prefix in `~/.npmrc`, point
   `~/.cache/Homebrew` at the disposable cache, seed the workspace from
   nanobot's templates and update the marked rules block in `AGENTS.md`, apply
   `EXTRA_PIXI_PACKAGES`, install the dependencies for `NANOBOT_CHANNELS`,
   bootstrap `config.json` when missing, then `exec` the gateway.

The `nanobot` phase never runs `brew update` or `brew upgrade`: brew is pinned by
the image, and bottles are installed only on demand.

## Quick start

```sh
cp .env.example .env
# Edit .env: at minimum set NANOBOT_WEB_TOKEN (or let the first start generate
# one and read it from the logs).

docker compose up -d                 # published nipakke/nanobot:latest
# or build locally instead:
# docker compose -f compose.yaml -f compose.build.yaml up -d --build
docker compose logs -f nanobot
```

Open <http://localhost:8765>. On the first start, the container creates
`/data/config/config.json` with the WebUI token from `NANOBOT_WEB_TOKEN`, or a
random token printed in the logs:

```
[entrypoint] WebUI: http://localhost:8765 — password: <token>
```

The token is stored as `channels.websocket.tokenIssueSecret` in
`/data/config/config.json`. `NANOBOT_WEB_TOKEN` only applies when the config is
first created; changing it later requires editing (or removing) `config.json`.

### Prebuilt image (Portainer)

`compose.yaml` is image-only and never builds. It runs
`${NANOBOT_IMAGE:-nipakke/nanobot:latest}`; set `NANOBOT_IMAGE` to a fixed tag
to stop following `latest` (see [tags](#tags)), then deploy the stack.

### Local builds

`compose.build.yaml` is an overlay that adds the `build:` section and build
args, and tags the result `${NANOBOT_BUILD_IMAGE:-nanobot-pixi:local}` so a
local build never shadows the published image:

```sh
docker compose -f compose.yaml -f compose.build.yaml up -d --build
```

Version pins live only in the `Dockerfile` (`NANOBOT_VERSION`,
`PIXI_VERSION`, `BREW_VERSION` + `BREW_COMMIT`, and the base images pinned by
digest) and are kept current by Renovate. `compose.build.yaml` passes a pin
through only when it is set in the environment or `.env`, so leave them unset
unless you deliberately build another version; a stale value in `.env` would
override the Dockerfile on every build. Other build args: `BUNDLE_TUI=0`,
`UID=1000`, `GID=1000`.

`BUNDLE_TUI=1` keeps the ~123 MiB native TUI binary in the image for
offline/air-gapped hosts; the default `0` removes it from the build stage, so
it is absent from every layer of the final image and the launcher downloads it
on first use instead (see [Native TUI](#native-tui)). `BREW_VERSION` and
`BREW_COMMIT` pin the Homebrew checkout and are verified against each other at
build time; bump both together.

```sh
# Offline bundle: keep the native TUI inside the image
BUNDLE_TUI=1 docker compose -f compose.yaml -f compose.build.yaml build
```

Multi-arch local build (published images are `linux/amd64` only for now):

```sh
docker buildx build --platform linux/amd64,linux/arm64 .
```

## Published image and updates

`docker.io/nipakke/nanobot` (`linux/amd64`) is built and published by GitHub
Actions, gated by the full A1–A22 acceptance suite.

### Tags

- `latest` and `<version>` (for example `0.4.2`) move to the newest verified
  build.
- `<version>-<YYYYMMDD>-<shortsha>` is immutable and is the rollback target.
  Pin a fixed tag in `NANOBOT_IMAGE` if you want no surprises; to roll back
  `latest` or `<version>`, re-tag the previous fixed tag.

### Automated updates (Renovate)

`renovate.json` tracks all pinned inputs (`Dockerfile` `ARG` pins, digest-pinned
base images, and GitHub Actions) with stable releases only (`ignoreUnstable`)
and a 2-day `minimumReleaseAge`:

- **`nanobot-ai`:** every stable release (majors included) opens its own PR as
  soon as it is 2 days old and auto-merges when the `test` workflow passes.
- **Base image digests, pixi, Homebrew, GitHub Actions (minor/patch/digest):**
  batched into one `monthly maintenance` PR on the 1st of each month,
  auto-merged when `test` passes. Base images stay on their `3.12`/`bookworm`
  tag line; only digests move.
- **Major updates of everything except `nanobot-ai`:** opened as separate PRs
  and wait for manual approval.

### Workflows

Two separate workflows keep pull requests isolated from registry credentials:

- `.github/workflows/test.yml` runs on `pull_request` only. It builds the image
  and runs `scripts/smoke-test.sh` (A1–A22) with no registry secrets and no
  push steps. Require this `test` check on `main` to gate auto-merges.
- `.github/workflows/publish.yml` runs only on `push` to `main` when files
  baked into the image change (`Dockerfile`, `entrypoint.sh`, `.dockerignore`,
  `scripts/**` excluding `smoke-*`, `etc/**`), or on manual `workflow_dispatch`.
  Docs, CI, and Renovate config changes never publish. It builds, runs A1–A22
  against that image, tags it, and pushes the exact tested image.

> **Dry-run state:** the Docker Hub login and `docker push` steps in
> `.github/workflows/publish.yml` are commented out until the Docker Hub
> repository and secrets are ready. Uncomment them after completing the setup
> below.

### One-time GitHub and Docker Hub setup

1. Create `nipakke/nanobot` on Docker Hub and create a Read & Write access token
   scoped to that repository.
2. Add repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` in GitHub.
3. Install the **Renovate** GitHub App on the repository.
4. In GitHub Settings → General, enable **Allow auto-merge**.
5. Add a branch protection rule / ruleset on `main` requiring the `test` status
   check to pass (without this, auto-merge does not wait for tests).
6. Uncomment the login and push steps in `.github/workflows/publish.yml`.

## Persistent trees and reset matrix

| Path | Environment | Contents | Wipe effect |
|---|---|---|---|
| `/data/config` | `NANOBOT_HOME` | config, sessions, memory, workspace | resets config/history; home/pixi/brew/cache survive |
| `/data/home` | `HOME`, uv tool dirs, `~/.local/bin`, `~/.npm` | dotfiles, SSH/CLI config, user files, uv tools, npm globals | resets home; config/pixi/brew/cache survive |
| `/data/pixi` | `PIXI_HOME` | pixi global envs, exposed binaries, global manifest | resets tools; config/home/brew/cache survive |
| `/data/brew` | `HOMEBREW_PREFIX` | Homebrew repo, Cellar, formula binaries | resets brew formulas; everything else survives |
| `/data/cache` | `XDG_CACHE_HOME`, pixi/uv/pip/brew caches, `PYTHONPYCACHEPREFIX` | 100% disposable caches, including compiled bytecode | safe to delete; tools/config survive; the first start after a wipe recompiles once |

With `compose.bind.yaml` the first, second, third, and fifth paths are
`./data/config`, `./data/home`, `./data/pixi`, and `./data/cache` on the host;
the wipe effects are identical. **`/data/brew` stays the `nanobot_brew` named
volume in both modes** — see [Homebrew](#homebrew).

`PATH` starts with `/data/pixi/bin:/data/home/.local/bin:/data/brew/bin`, then
`/app/.venv/bin`, so a tool installed with pixi, `npm -g`, or `brew` is usable
immediately.

The agent's exec tool builds a clean child environment instead of inheriting
the container environment, so bootstrap gives a new config two exec defaults:
`tools.exec.pathPrepend` names those four directories, and
`tools.exec.allowedEnvKeys` forwards `PIXI_HOME`, `PIXI_CACHE_DIR`,
`PIXI_NO_TELEMETRY`, `XDG_CACHE_HOME`, `UV_CACHE_DIR`, `UV_LINK_MODE`,
`PIP_CACHE_DIR`, `PYTHONPYCACHEPREFIX`, `NANOBOT_HOME`, and `TZ` so agent-run
tools see pixi environments, keep caches in `/data/cache`, and respect the
configured timezone. An existing config needs the same values (WebUI or
`config.json`) before the agent can see pixi, `npm`, and `brew` tools cleanly.

Image:

| Path | Persistence |
|---|---|
| `/app/.venv` | ephemeral, owned by `nanobot`, never mounted over |
| `/etc/nanobot-env.md` | baked read-only cheat sheet (mode 0444) |
| root filesystem | ephemeral |

### Reset examples

```sh
# Wipe only caches (safe; tools and config survive)
docker compose exec -u nanobot nanobot sh -c 'rm -rf /data/cache/*'

# Wipe pixi tools (EXTRA_PIXI_PACKAGES reinstalls them on next start)
docker compose down
docker volume rm nanobot_nanobot_pixi
docker compose up -d

# Wipe home (config survives)
docker compose down
docker volume rm nanobot_nanobot_home
docker compose up -d

# Wipe config only (home/pixi/brew/cache survive)
docker compose down
docker volume rm nanobot_nanobot_config
docker compose up -d

# Wipe Homebrew (formula binaries; the image seed is restored on next start)
docker compose down
docker volume rm nanobot_nanobot_brew
docker compose up -d
```

In bind mode the same resets are folder operations after `docker compose down`:
`rm -rf ./data/cache/*` (safe), `rm -rf ./data/pixi` (tools reinstall),
`rm -rf ./data/home`, or `rm -rf ./data/config` (config and history). Homebrew is
not part of `./data`: use `docker volume rm nanobot_nanobot_brew` as above.

`docker compose stop` is not enough: a stopped container still references its
volumes, so `docker volume rm` fails until the container is removed with
`down` or `rm`.

`docker compose down -v` removes all five volumes. Back up config with a
one-off container running as `nanobot` (so the archive is not root-owned);
stop the gateway first for a consistent SQLite copy:

```sh
docker compose stop nanobot
docker compose run --rm -T -u nanobot nanobot \
  tar -C /data -czf - config > nanobot-config.tgz
docker compose start nanobot
```

Restore the same way:

```sh
docker compose stop nanobot
docker compose run --rm -T -u nanobot nanobot \
  tar -C /data -xzf - < nanobot-config.tgz
docker compose start nanobot
```

## Privilege model

The image's configured user is root because the setup phase must create and
chown fresh, root-owned named volumes. Immediately after setup the entrypoint
runs:

```sh
exec setpriv --reuid=nanobot --regid=nanobot --init-groups "$0" "$@"
```

The gateway therefore runs as UID/GID 1000 with
`CapEff: 0000000000000000`. There is no `sudo`, no setuid helper, and no
passwordless escalation. `bubblewrap` is not installed: it cannot work under
`cap_drop: ALL` + `no-new-privileges` without a relaxed seccomp profile, so a
sandboxed exec profile is out of scope for this image.

Compose grants exactly the setup capabilities and drops the rest:

```yaml
cap_drop: [ALL]
cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]
security_opt: [no-new-privileges:true]
```

`DAC_OVERRIDE` is needed so the ownership scan can descend into `0700`
directories such as `/data/home/.ssh`. All capabilities are cleared by the
`setpriv` drop.

### `docker exec` defaults to root

Because the image user is root, **plain `docker exec` also runs as root** and
can create root-owned files in `/data`. Always pass `-u nanobot`:

```sh
docker compose exec -u nanobot nanobot nanobot status
docker compose exec -it -u nanobot nanobot nanobot
```

This is a Docker constraint, not a preference: the image cannot have a default
exec user and still perform the root-owned volume setup.

## pixi and runtime tools

The bot runs as `nanobot`, so `pixi` is the supported path for native/CLI tools:

```sh
pixi search <term>
pixi info <pkg>
pixi global install <pkg>
pixi global list
```

`EXTRA_PIXI_PACKAGES` installs each package into its own global environment at
startup, for example `jq,ripgrep` becomes `/data/pixi/envs/jq` and
`/data/pixi/envs/ripgrep`. Existing environments are detected exactly
(`/data/pixi/envs/<pkg>` or `[envs.<pkg>]` in the global manifest) and are not
reinstalled on restart. A failed install logs a warning and does not block the
gateway.

`PIXI_NO_TELEMETRY=1` is set in the image.

The full cheat sheet is baked into `/etc/nanobot-env.md` (mode 0444), but
nothing reads it automatically. What the agent does read is the workspace
`AGENTS.md`, so the entrypoint maintains a marked rules block there — see
[Rules the agent actually sees](#rules-the-agent-actually-sees).

## Homebrew

Homebrew is installed into the image at `/data/brew` and persisted on its own
named volume (`nanobot_brew`). It exists for WebUI Apps whose install command is
`brew install <pkg>`: those binaries land in `/data/brew/bin`, which is on
`PATH`, and survive restarts, recreates and image upgrades. The baked tree is
about 80 MB (mostly Homebrew's vendored portable Ruby; its image layer is about
83 MB), and the source is pinned to a release tag and commit (`BREW_VERSION` /
`BREW_COMMIT` in `Dockerfile`), verified at build time. `docs`, `manpages`,
`completions` and `.github` are pruned; `.git` stays because Homebrew reports
its concrete version from it.

```sh
docker compose exec -u nanobot nanobot brew --version
docker compose exec -u nanobot nanobot brew --prefix       # /data/brew
docker compose exec -u nanobot nanobot brew install tree   # -> /data/brew/bin/tree
```

- **Why a separate volume, not `./data`.** Homebrew rewrites its own git
  checkout (auto-update) and unpacks bottles by the hundred megabytes. On
  Windows a `./data` bind is a 9p/drvfs share, and that kind of write churn is
  both slow and has already destabilised the Docker engine on this host.
  `/data/brew` therefore stays a named volume (ext4) even with
  `compose.bind.yaml`; `docker compose -f compose.yaml -f compose.bind.yaml
  config` shows four binds and exactly one volume, at `/data/brew`.
- **The image env is not what brew sees in the WebUI.** nanobot's app runner
  (`apps/cli/service.py:_subprocess_env`) starts installs with only `HOME`,
  `LANG`, `TERM`, `PATH`, and `PYTHONUNBUFFERED`. No `HOMEBREW_*` variable from
  the image reaches `brew`. It nevertheless works because `brew` derives its
  prefix from the location of `bin/brew` (`/data/brew/bin/brew` ->
  `../Homebrew/bin/brew`), and because Homebrew's portable Ruby is vendored at
  build time. `$HOME/.local/bin/brew` is a symlink to a wrapper that restores
  the missing `HOMEBREW_*` values before running the real `bin/brew` — see
  [The brew wrapper on PATH](#the-brew-wrapper-on-path).
- **Zip casks need `unzip`.** The image ships `/usr/bin/unzip`; without it
  Homebrew's ZIP strategy looks up `Formula["unzip"]` inside its sandbox, which
  fails on a cold API cache (`brew install --cask 1password-cli` aborts).
- **Bottle cache.** With the image env, `HOMEBREW_CACHE=/data/cache/brew`. Under
  the WebUI's stripped env brew would fall back to `$HOME/.cache/Homebrew`, so
  the entrypoint symlinks that path to `/data/cache/brew`: downloads stay in the
  disposable cache tree. A fresh `brew install` of `jq` pulls roughly 1.1 GB of
  bottles (linux-headers, glibc, gcc, binutils, ...); plan volume size
  accordingly. Simple formulas (`tree`) are one small bottle.
- **Reset.** `docker compose down && docker volume rm nanobot_nanobot_brew &&
  docker compose up -d` restores the image seed (repo + vendored Ruby, no
  formulas). Nothing else is touched.
- **Backup** is not usually worth it: formulas are reinstalled on demand. For a
  cold copy: `docker run --rm -v nanobot_nanobot_brew:/data/brew -v "$PWD":/out
  -u nanobot <image> tar -C /data -czf /out/brew.tgz brew`.
- Brew is never updated or upgraded by the entrypoint. It is pinned by the
  image; rebuild with new `BREW_VERSION`/`BREW_COMMIT` values to refresh it.

### The brew wrapper on PATH

`scripts/brew-wrapper.sh` is copied into the image as
`/usr/local/bin/nanobot-brew`, and the `nanobot` phase of the entrypoint links
`$HOME/.local/bin/brew` to it. Because `$HOME/.local/bin` precedes
`/data/brew/bin` on `PATH`, both `docker compose exec -u nanobot nanobot brew ...`
and a WebUI `brew install` reach the wrapper instead of the binary directly.

The wrapper restores the image's defaults and then `exec`s the real binary:

```sh
HOMEBREW_PREFIX=/data/brew
HOMEBREW_CELLAR=/data/brew/Cellar
HOMEBREW_REPOSITORY=/data/brew/Homebrew
HOMEBREW_CACHE=/data/cache/brew
HOMEBREW_NO_AUTO_UPDATE=1
HOMEBREW_NO_ANALYTICS=1
HOMEBREW_NO_ENV_HINTS=1
```

Path values use `:=` defaults, while the three boolean flags use `=` defaults
(`: "${VAR=1}"`). Because Homebrew treats any non-empty value (including `0`) as
set, pass an empty value to clear a boolean flag (`HOMEBREW_NO_AUTO_UPDATE= brew ...`);
an explicit value in the environment always wins.

`HOMEBREW_NO_AUTO_UPDATE` is the one that matters. Without it, every WebUI
`brew install` starts with `brew update`, a git fetch that rewrites the
repository in `/data/brew`. That write burst repeatedly took the Docker engine
down on the Windows/WSL host this image was built on (`docker exec` -> HTTP
500, then the WSL bootstrap failing with `0xc00000fd`). The wrapper adds no
capability; it only keeps brew from rewriting its own checkout on each install.

If `$HOME/.local/bin/brew` already exists as a regular file or as a symlink to
another target, the entrypoint warns and leaves it alone. That `brew` keeps its
own behaviour, including auto-update; nothing is overwritten.

## npm and JS tools

The image sets `npm_config_prefix=/data/home/.local` and
`npm_config_cache=/data/home/.npm`, and the entrypoint records the same two
values in `~/.npmrc`. Both buses exist because the WebUI app runner strips the
environment: `npm install -g <pkg>` there sees only `HOME`, `LANG`, `TERM`,
`PATH`, `PYTHONUNBUFFERED`, and `npm` reads its global prefix from
`$HOME/.npmrc`. Without that file the install would land inside the node
environment (`/data/pixi/envs/nodejs`), which is not on `PATH`, and the app
runner's `shutil.which(entry_point)` check would fail even though the install
succeeded.

Result: globally installed JS CLIs appear in `/data/home/.local/bin`, are on
`PATH` (also inside the stripped env), and survive recreates and upgrades.

```sh
docker compose exec -u nanobot nanobot npm install -g cowsay
docker compose exec -u nanobot nanobot sh -c 'command -v cowsay'   # /data/home/.local/bin/cowsay
```

`npx <pkg>` needs no prefix: its cache is `$HOME/.npm`, in the persistent home
tree.

## WebUI Apps durability

| Install strategy used by the app | Lands in | Survives recreate | Survives image upgrade |
|---|---|---|---|
| `brew` | `/data/brew` (named volume) | yes | yes |
| `npm` | `/data/home/.local/bin` + `~/.npm` | yes | yes |
| `pip` | `/app/.venv` | **no** (image layer, rebuilt) | **no** |
| `uv` tool | `/data/home/.local` | yes | yes |

`pip` is the one strategy the image cannot make durable: the app runner installs
into the venv that ships in the image, and that venv is replaced on every
recreate. Channel dependencies are the exception and are replayed at startup
(see [`NANOBOT_CHANNELS`](#channel-python-dependencies-nanobot_channels)).

## Rules the agent actually sees

nanobot injects the workspace `AGENTS.md` (plus `SOUL.md` and `USER.md`) into
the agent context, and skips a file while it still equals the bundled template.
`/etc/nanobot-env.md` is never read automatically. The entrypoint therefore runs
`scripts/workspace-agents-env.py`, which:

- seeds the workspace from nanobot's own templates (`sync_workspace_templates`,
  the same call the gateway makes: only missing files are created);
- maintains one block between `<!-- nanobot-image-env:begin -->` and
  `<!-- nanobot-image-env:end -->` stating the durable rules: no `apt`/`apk` and
  no `sudo`, `pixi global install` for native tools, `npx`/`npm i -g` for JS
  tools, brew at `/data/brew` reserved for WebUI Apps (not ad-hoc installs),
  `/app/.venv` is ephemeral, `nanobot update` is rejected, and which `/data`
  trees survive what.

Re-running is idempotent: the block is replaced in place, never duplicated, and
text outside the markers is left untouched. Because the seeded file no longer
equals the bundled template, the rules are injected from the first start.

## Channel Python dependencies (`NANOBOT_CHANNELS`)

`NANOBOT_CHANNELS` installs the Python dependencies declared by channel
manifests at startup, before the gateway runs:

```sh
# .env
NANOBOT_CHANNELS=discord,telegram,slack
```

Names are resolved against nanobot's own channel registry, so each channel's
declared requirements come from its manifest (for example `discord.py` for
Discord and `python-telegram-bot` for Telegram). Everything missing is
installed into `/app/.venv` in one
`uv pip install --python /app/.venv/bin/python ...` call, with wheels cached in
`/data/cache/uv` and `UV_LINK_MODE=copy`.

- Satisfied requirements are detected from installed distribution metadata, so
  a plain restart does not invoke uv and adds no install work.
- A recreated container starts from the image's venv, so the install is
  replayed; the wheels come from `/data/cache/uv`, not the network.
- Failures are non-fatal: an unknown channel name, a resolution error, or a
  network failure logs a `WARNING` (naming the known channels) and the gateway
  still starts.
- Enabling a channel through the WebUI does not need this variable: nanobot
  installs the manifest dependencies for enabled channels itself. Use
  `NANOBOT_CHANNELS` to pre-seed dependencies (for example on an air-gapped
  host) or to avoid the install on first enable.

The packages live only in the container's `/app/.venv`. Keep
`NANOBOT_CHANNELS` set and the dependencies are replayed on every recreate;
remove it and a new container starts without them.

`NANOBOT_CHANNELS` is entrypoint-only: nanobot's own settings use the
`NANOBOT_` environment prefix, where that name would be read as the whole
channels mapping. The entrypoint consumes and unsets it before starting the
gateway, and the venv's `sitecustomize.py` drops it at interpreter startup so
ad-hoc `docker exec ... nanobot ...` commands are unaffected.

## Commands

```sh
# Status (note -u nanobot; first `nanobot` is the Compose service, second is the CLI)
docker compose exec -u nanobot nanobot nanobot status

# Interactive TUI
docker compose exec -it -u nanobot nanobot nanobot

# Logs
docker compose logs -f nanobot

# Health (container side)
docker compose exec -u nanobot nanobot /app/.venv/bin/python -B /usr/local/bin/healthcheck.py

# Health (host side; NANOBOT_HEALTH_HOST_PORT is the host port)
curl -fsS http://127.0.0.1:18790/health
```

### Health ports

- `NANOBOT_HEALTH_HOST_PORT` moves only the host-published port.
- `NANOBOT_HEALTH_PORT` is the container-side health port and the value the
  healthcheck reads. It defaults to `18790` and should only change together
  with `gateway.port` in `config.json`.

The WebUI port is `${NANOBOT_WEB_BIND:-0.0.0.0}:${NANOBOT_WEB_PORT:-8765}` on
the host, mapped to `8765` in the container. Set `NANOBOT_WEB_BIND=127.0.0.1` in
`.env` to restrict plaintext WebUI access to localhost.

### Native TUI

The default image does not contain the ~123 MiB native TUI binary. The upstream
launcher notices the packaged path is absent and downloads the
checksum-verified release asset for `NANOBOT_VERSION` on first use, into
`/data/config/bin/tui/<version>`; recreates reuse that copy. `NANOBOT_TUI_NO_DOWNLOAD=1`
disables the download and leaves the launcher's documented
`TuiUnavailableError` (`use nanobot agent --classic`). For air-gapped hosts,
build with `BUNDLE_TUI=1` to keep the binary in the image; the packaged path
then resolves without network.

### Python bytecode

The image ships no `.pyc`. `PYTHONPYCACHEPREFIX=/data/cache/pycache` makes the
first start compile imported modules once into the disposable cache tree;
restarts and recreates reuse those files, and wiping `/data/cache` only costs
one recompile. The healthcheck keeps `-B`, so Docker's root-executed check
never writes bytecode.

## Time zone

Set `TZ` in `.env` (for example `Europe/Budapest`) and recreate the container:

```sh
docker compose up -d --force-recreate
docker compose exec -u nanobot nanobot date
```

## Upgrades

In-container `nanobot update` is rejected: changes would live in the ephemeral
container layer and disappear on the next recreate. The entrypoint enforces
this for container starts and `docker compose run ... update`; `docker exec`
bypasses entrypoint logic by design, so use Compose for launch commands.

Upgrade by pulling the new published tag (or pinning the new fixed tag in
`NANOBOT_IMAGE`):

```sh
docker compose pull
docker compose up -d
```

For local builds, override `NANOBOT_VERSION` and `NANOBOT_BUILD_IMAGE` (or bump
the `Dockerfile` pin):

```sh
NANOBOT_BUILD_IMAGE=nanobot-pixi:0.5.0 NANOBOT_VERSION=0.5.0 \
  docker compose -f compose.yaml -f compose.build.yaml build
NANOBOT_IMAGE=nanobot-pixi:0.5.0 docker compose up -d
```

Set both values when overriding locally: `NANOBOT_VERSION` changes the package
inside the image, while `NANOBOT_BUILD_IMAGE` / `NANOBOT_IMAGE` control the tag
Compose builds and runs. Reusing the old tag makes the tag lie about its
contents.

Back up `/data/config` first. `/data/home`, `/data/pixi`, `/data/brew`, and
`/data/cache` survive. A pixi version bump keeps `/data/pixi`; if a new pixi
cannot read old global environments, wipe `/data/pixi` and let
`EXTRA_PIXI_PACKAGES` reinstall.

What survives an image upgrade, per install mechanism: `brew` formulas
(`/data/brew`), `npm -g` packages (`/data/home/.local`), `uv tool` installs
(`/data/home/.local`), pixi globals (`/data/pixi`), config/sessions/workspace
(`/data/config`). What does not: `pip install` into `/app/.venv` and anything
else in the root filesystem. A rebuilt image brings the Homebrew release pinned
by `BREW_VERSION`/`BREW_COMMIT`; existing Cellar entries from the old volume
still work, and `brew upgrade` is available if a formula needs refreshing. The
TUI download cache in `/data/config/bin/tui` also survives.

The workspace `AGENTS.md` block is rewritten in place on start when its wording
changes, so an upgraded image updates the agent's rules without duplicating
them.

## Host support and persistence modes

The image uses the same five trees inside the container, with `/data/brew`
always on a named volume. How the other four are stored is a Compose choice:

- **Named volumes (default).** `compose.yaml` on its own; verified on Linux and
  Docker Desktop, and the image-only/Portainer path.
- **Bind mounts.** `compose.bind.yaml` on top of `compose.yaml` keeps the four
  trees in `./data` on the host:

```sh
docker compose -f compose.yaml -f compose.bind.yaml up -d
```

Compose merges `volumes` by target path, so each entry replaces the named
volume at the same container path instead of adding a second mount.
`docker compose -f compose.yaml -f compose.bind.yaml config` shows four bind
mounts plus the `nanobot_brew` volume at `/data/brew`.

| Host folder | Container path | Contents |
|---|---|---|
| `./data/config` | `/data/config` | config, sessions, memory, workspace |
| `./data/home` | `/data/home` | `HOME`: dotfiles, SSH/CLI config, uv tools, npm globals |
| `./data/pixi` | `/data/pixi` | pixi global environments |
| `./data/cache` | `/data/cache` | disposable caches |

`/data/brew` is deliberately **not** in the table and not in the overlay: it
stays the `nanobot_brew` named volume because Homebrew's git checkout and bottle
unpacking must not run on a 9p bind (see [Homebrew](#homebrew)).
`docker compose -f compose.yaml -f compose.bind.yaml config` shows exactly that:
four binds plus one named volume at `/data/brew`.

`./data` is in `.gitignore`; never commit it. Docker creates the four
directories on first start and the entrypoint's root phase adopts them. Back up
by stopping the stack and copying `./data`; `./data/cache` can be deleted at
any time.

Verified in bind mode: fresh empty directories produce a healthy start,
`/data/home/.nanobot -> /data/config` is created and kept across a recreate and
`down`/`up`, `nanobot` can write in all four trees, `config.json`, sessions and
workspace survive `down` + `up`, `.ssh` keeps mode `0700` across a recreate, and
`NANOBOT_CHANNELS` installs land in `/app/.venv` with the wheels cached in
`./data/cache/uv`.

Windows notes: Docker Desktop's filesystem layer reports the four directories
as `0777` owned by `nanobot`. Unix modes are emulated and Windows ACLs are not
mapped, so container permissions do not protect the folder on Windows; it is as
accessible as any other folder on that drive. On Linux, chown the four host
directories to the build UID/GID (default `1000:1000`); the entrypoint fails
loudly when `nanobot` cannot write them.

Run one container per data folder. Two gateways sharing the same `./data`
corrupt sessions and race on the workspace Git store: when both create `.git`
at the same moment, the loser logs
`GitStoreError: Git store init failed for /data/config/workspace` with a
dulwich `FileExistsError` cause and starts without memory history. The winner
is unaffected.

## Notes

- `NANOBOT_HOME=/data/config` is an image-level helper variable, not an
  upstream nanobot 0.4.2 variable. The venv includes a tiny
  `sitecustomize.py` that selects it as nanobot's default home so
  `nanobot status` reports `/data/config/config.json`; the
  `/data/home/.nanobot -> /data/config` symlink keeps filesystem-based
  resolution consistent.
- **Why `~/.nanobot` stays a symlink.** nanobot 0.4.2 does not route every path
  through `set_home_path()`: the update/data-access locks
  (`nanobot/data_access.py`, `nanobot/installation_lock.py`), the bun tool
  cache (`nanobot/bun.py`), QQ media (`nanobot/channels/qq/runtime.py`) and the
  gateway default config path (`nanobot/gateway/runtime.py:_default_config_path`)
  are built from `Path.home()`. The symlink is what keeps that state inside
  `/data/config`; without it a container creates a real
  `/data/home/.nanobot/updates/data-locks` and splits instance state across the
  home and config trees. Removing it would require patching those call sites.
- `NANOBOT_CHANNELS` is also image-level and entrypoint-only. nanobot's
  settings use the `NANOBOT_` prefix, so the variable would otherwise be parsed
  as the whole channels mapping; the entrypoint unsets it and the same
  `sitecustomize.py` drops it for ad-hoc `docker exec` processes.
- Channel Python dependencies installed into `/app/.venv` at runtime are
  ephemeral and replayed on the next start, sped up by the caches in
  `/data/cache`. `NANOBOT_CHANNELS` automates that at startup from the channel
  manifests' own requirements.
- `HOMEBREW_*` and `npm_config_*` are image-level, and the WebUI app runner
  strips them. Persistence comes from where things live (`/data/brew`, and
  `~/.npmrc` + `~/.cache/Homebrew` for npm/brew caches), not from the env: the
  wrapper behind `~/.local/bin/brew` restores the `HOMEBREW_*` defaults for
  that path, and `npm` reads its prefix from `~/.npmrc`.
- The healthcheck uses `/app/.venv/bin/python -B` and stdlib only; it does not
  require curl and does not leave root-owned `__pycache__` files.

## Live verification

The acceptance suite builds the image and runs checks A1–A22 (entrypoint,
ownership, PID 1, symlink, pixi extras and idempotency, persistence, cache
wipe, TZ, health, bootstrap with flags, symlink safety, `nanobot update`
rejection, uv tools, cheat sheet, `NANOBOT_CHANNELS` installs, idempotency,
offline cache replay, unknown-channel handling, and — A22 — Homebrew on its own
volume with a real bottle install through the app runner's env allowlist plus
the npm global prefix and the `AGENTS.md` rules block):

```sh
bash scripts/smoke-test.sh
```

A22 installs `tree` (one small bottle) by default. `jq` needs
linux-headers/glibc/gcc/binutils (~1.1 GB of bottles) and is opt-in:

```sh
NANOBOT_SMOKE_BREW_FORMULA=jq bash scripts/smoke-test.sh
```

A22 also asserts that `command -v brew` resolves to `$HOME/.local/bin/brew`,
that this link resolves to `/usr/local/bin/nanobot-brew`, and that the install
log contains no `Auto-updating Homebrew` line.

It uses a unique Compose project name, container name
(`nanobot-smoke-<pid>-nanobot`), and host ports (18766 web, 18791 health), so it
can run next to a live stack. Both host ports are overridable with
`NANOBOT_SMOKE_WEB_PORT` / `NANOBOT_SMOKE_HEALTH_PORT`; on Windows hosts whose
excluded port ranges cover the defaults, Docker Desktop fails with
`forwards/expose ... 500` and an access-denied bind, so pick free ports. To test
an image that is already built (as CI does), set
`NANOBOT_SMOKE_IMAGE=<ref> NANOBOT_SMOKE_SKIP_BUILD=1`. Expected versions in A4
and A21 are read from the `Dockerfile` `ARG` defaults. It cleans up only its own
containers, volumes, and network.

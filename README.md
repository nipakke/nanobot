# nanobot + pixi in Docker

Run `nanobot-ai==0.4.2` in a reproducible Debian container with:

- pixi as the supported way for the bot to install native/CLI tools at runtime;
- a dedicated non-root `nanobot` user (UID/GID 1000) with no `sudo`;
- four independent persistent trees, so config, home, tools, and caches can be
  reset separately;
- an image-baked, ephemeral `/app/.venv` that changes only with the image tag
  (writable by `nanobot` for channel dependency installs, but never mounted).

The image starts as root only for the entrypoint setup phase, then drops to
`nanobot` with `setpriv`. See [Privilege model](#privilege-model).

## Architecture

```
image layers (ephemeral)                 named volumes (persistent)
┌──────────────────────────────┐         ┌──────────────────────────────┐
│ /app/.venv   nanobot 0.4.2   │         │ nanobot_config -> /data/config│
│ /usr/local/bin/pixi          │         │   config.json, sessions,      │
│ /usr/local/bin/uv, uvx       │         │   memory, workspace           │
│ OS packages, tini, health    │         ├──────────────────────────────┤
└──────────────────────────────┘         │ nanobot_home -> /data/home    │
                                         │   HOME, dotfiles, uv tools    │
                                         ├──────────────────────────────┤
/data/home/.nanobot -> /data/config      │ nanobot_pixi -> /data/pixi    │
  (symlink, created at startup)          │   pixi global envs + binaries │
                                         ├──────────────────────────────┤
                                         │ nanobot_cache -> /data/cache  │
                                         │   disposable pixi/uv/pip cache│
                                         └──────────────────────────────┘
```

The startup order is:

1. root: create `/data/{config,home,pixi,cache}`, establish the
   `/data/home/.nanobot -> /data/config` symlink, fix mismatched ownership;
2. `setpriv` drops to `nanobot`;
3. `nanobot` phase: apply `EXTRA_PIXI_PACKAGES`, bootstrap `config.json` when
   missing, then `exec` the gateway.

## Quick start

```sh
cp .env.example .env
# Edit .env: at minimum set NANOBOT_WEB_TOKEN (or let the first start generate
# one and read it from the logs).

docker compose -f compose.yaml -f compose.build.yaml up -d --build
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

`compose.yaml` is image-only and never builds. Point `NANOBOT_IMAGE` at the
published image reference, then deploy the stack. No registry credentials, CI,
or publishing are part of this repository.

### Local builds

`compose.build.yaml` is an overlay that adds the `build:` section and build
args:

```sh
docker compose -f compose.yaml -f compose.build.yaml up -d --build
```

Build args: `NANOBOT_VERSION=0.4.2`, `PIXI_VERSION=v0.84.2`, `UID=1000`,
`GID=1000`.

Multi-arch (publishing is out of scope):

```sh
docker buildx build --platform linux/amd64,linux/arm64 .
```

## Persistent trees and reset matrix

| Path | Environment | Contents | Wipe effect |
|---|---|---|---|
| `/data/config` | `NANOBOT_HOME` | config, sessions, memory, workspace | resets config/history; home/pixi/cache survive |
| `/data/home` | `HOME`, uv tool dirs | dotfiles, SSH/CLI config, user files, uv tools | resets home; config/pixi/cache survive |
| `/data/pixi` | `PIXI_HOME` | pixi global envs, exposed binaries, global manifest | resets tools; config/home/cache survive |
| `/data/cache` | `XDG_CACHE_HOME`, pixi/uv/pip caches | 100% disposable caches | safe to delete; tools/config survive |

`PATH` starts with `/data/pixi/bin:/data/home/.local/bin:/app/.venv/bin`, so a
tool installed with pixi is usable immediately.

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

# Wipe config only (home/pixi/cache survive)
docker compose down
docker volume rm nanobot_nanobot_config
docker compose up -d
```

`docker compose stop` is not enough: a stopped container still references its
volumes, so `docker volume rm` fails until the container is removed with
`down` or `rm`.

`docker compose down -v` removes all four volumes. Back up config with a
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
docker compose exec -u nanobot nanobot status
docker compose exec -it -u nanobot nanobot
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

The same guidance is baked into `/etc/nanobot-env.md` (mode 0444). Add
"Read /etc/nanobot-env.md before installing tools" to the bot's instructions so
it does not try `apt`, `apk`, or `sudo`.

## Commands

```sh
# Status (note -u nanobot)
docker compose exec -u nanobot nanobot status

# Interactive TUI
docker compose exec -it -u nanobot nanobot

# Logs
docker compose logs -f nanobot

# Health (container side)
docker compose exec -u nanobot /app/.venv/bin/python -B /usr/local/bin/healthcheck.py

# Health (host side; NANOBOT_HEALTH_HOST_PORT is the host port)
curl -fsS http://127.0.0.1:18790/health
```

### Health ports

- `NANOBOT_HEALTH_HOST_PORT` moves only the host-published port.
- `NANOBOT_HEALTH_PORT` is the container-side health port and the value the
  healthcheck reads. It defaults to `18790` and should only change together
  with `gateway.port` in `config.json`.

The WebUI port is `${NANOBOT_WEB_PORT:-8765}` on the host, mapped to `8765` in
the container.

## Time zone

Set `TZ` in `.env` (for example `Europe/Budapest`) and recreate the container:

```sh
docker compose up -d --force-recreate
docker compose exec -u nanobot date
```

## Upgrades

In-container `nanobot update` is rejected: changes would live in the ephemeral
container layer and disappear on the next recreate. The entrypoint enforces
this for container starts and `docker compose run ... update`; `docker exec`
bypasses entrypoint logic by design, so use Compose for launch commands.
Upgrade by rebuilding the image with a new version:

```sh
NANOBOT_IMAGE=nanobot-pixi:0.5.0 NANOBOT_VERSION=0.5.0 \
  docker compose -f compose.yaml -f compose.build.yaml build
NANOBOT_IMAGE=nanobot-pixi:0.5.0 docker compose up -d
```

Set both values: `NANOBOT_VERSION` changes the package inside the image, while
`NANOBOT_IMAGE` is the tag Compose actually runs. Reusing the old tag is
possible but makes the tag lie about its contents.

Back up `/data/config` first. `/data/home`, `/data/pixi`, and `/data/cache`
survive. A pixi version bump keeps `/data/pixi`; if a new pixi cannot read old
global environments, wipe `/data/pixi` and let `EXTRA_PIXI_PACKAGES` reinstall.

## Host support and bind mounts

Named volumes are the verified path on Linux and Docker Desktop. Bind mounts are
Linux-only for this image: host ownership is the operator's responsibility, and
the entrypoint fails loudly if the container user cannot write the mounted
directories. There is no non-root workaround for Docker Desktop bind mounts.
Chown host directories to the build UID/GID (default `1000:1000`).

## Notes

- `NANOBOT_HOME=/data/config` is an image-level helper variable, not an
  upstream nanobot 0.4.2 variable. The venv includes a tiny
  `sitecustomize.py` that selects it as nanobot's default home so
  `nanobot status` reports `/data/config/config.json`; the
  `/data/home/.nanobot -> /data/config` symlink keeps filesystem-based
  resolution consistent.
- Channel Python dependencies installed into `/app/.venv` at runtime are
  ephemeral and replayed on the next start, sped up by the caches in
  `/data/cache`.
- The healthcheck uses `/app/.venv/bin/python -B` and stdlib only; it does not
  require curl and does not leave root-owned `__pycache__` files.

## Live verification

The acceptance suite builds the image and runs checks A1–A20 (entrypoint,
ownership, PID 1, symlink, pixi extras and idempotency, persistence, cache
wipe, TZ, health, bootstrap with flags, symlink safety, `nanobot update`
rejection, uv tools, cheat sheet):

```sh
bash scripts/smoke-test.sh
```

It uses a unique Compose project name and cleans up only its own containers
and volumes.

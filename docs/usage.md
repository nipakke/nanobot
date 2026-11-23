# Usage, backups & upgrades

## Common commands

Always pass `-u nanobot` to `docker compose exec` (plain `exec` runs as root):

```sh
# Status & interactive TUI
docker compose exec -u nanobot nanobot nanobot status
docker compose exec -it -u nanobot nanobot nanobot

# Install a persistent CLI tool
docker compose exec -u nanobot nanobot pixi global install ripgrep

# Logs & healthcheck
docker compose logs -f nanobot
curl -fsS http://127.0.0.1:18790/health
```

## Upgrading

In-container `nanobot update` is disabled because `/app/.venv` lives in the
image layer. Back up `./data/config`, then pull and recreate:

```sh
docker compose pull
docker compose up -d
```

Available tags on `docker.io/nipakke/nanobot`:

- `latest` — newest verified build.
- `<version>` (e.g. `0.4.2`) — moving tag for that `nanobot-ai` release.
- `<version>-<YYYYMMDD>-<shortsha>` — immutable tag for pinning or rollback.

## Persistent `/data` layout

| Path | Contents | Wipe effect |
|---|---|---|
| `/data/config` | `config.json`, sessions, memory, workspace, TUI binary | Resets config & history; tools/home/cache survive |
| `/data/home` | `HOME`, dotfiles, `uv` tools, `npm -g` bins (`~/.local/bin`) | Resets home; config/pixi/brew/cache survive |
| `/data/pixi` | `pixi` global envs and binaries | `EXTRA_PIXI_PACKAGES` reinstall on next start |
| `/data/brew` | Homebrew repo, Cellar, WebUI App bottles | Resets brew apps; image seed restored on next start |
| `/data/cache` | `pixi`/`uv`/`pip`/`brew` caches and Python `pycache` | 100% disposable; safe to delete anytime |

`/app/.venv` and the rest of the root filesystem are ephemeral.

## Backup & restore `/data/config`

Stop the gateway first for a consistent SQLite snapshot:

```sh
# Backup
docker compose stop nanobot
tar -C ./data -czf nanobot-config.tgz config
docker compose start nanobot

# Restore
docker compose stop nanobot
tar -C ./data -xzf nanobot-config.tgz
docker compose start nanobot
```

## Resetting data or caches

```sh
# Wipe disposable caches (safe while running)
docker compose exec -u nanobot nanobot sh -c 'rm -rf /data/cache/*'

# Wipe one subtree (e.g. ./data/pixi, ./data/home, ./data/config, or ./data/brew)
docker compose down
rm -rf ./data/pixi
docker compose up -d
```

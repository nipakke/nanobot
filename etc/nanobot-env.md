# nanobot environment — read this before installing tools

You are the `nanobot` user (UID/GID 1000), not root.

- There is **no `sudo`**, no passwordless escalation, and no writable root.
- **Do not run `apt`, `apt-get`, or `apk`.** System packages are fixed in the
  image. They would also be lost when the container is recreated.

## Where tools go

| Tool | Command | Binaries land in | Persists? |
|---|---|---|---|
| native / CLI (preferred) | `pixi global install <pkg>` | `/data/pixi/bin` | yes |
| WebUI Apps only (Homebrew) | WebUI Apps screen (`brew`) | `/data/brew/bin` | yes (own volume) |
| JS one-shot | `npx <pkg>` | cache in `$HOME/.npm` | cache yes |
| JS global | `npm i -g <pkg>` | `/data/home/.local/bin` | yes |
| Python (image only) | `pip install <pkg>` | `/app/.venv` | **no** |

`pixi search <term>`, `pixi info <pkg>`, `pixi global list` discover packages.
Homebrew lives at `/data/brew` (`brew --prefix` reports it) and is reserved for
WebUI Apps; do not use `brew` for ad-hoc tool installs—use `pixi global install`
instead.

**WebUI Apps**: brew ✅, npm ✅, pip ❌ for durability — a pip install writes to
`/app/.venv`, which is rebuilt from the image on every recreate.

## What survives a container restart, recreate, or image upgrade

| Path | Contents | Persists? |
|---|---|---|
| `/data/config` | config, sessions, memory, workspace | yes |
| `/data/home` | dotfiles, SSH/CLI config, `~/.local` bins, uv tools | yes |
| `/data/pixi` | pixi global environments and tools | yes |
| `/data/brew` | Homebrew prefix: repo, Cellar, bottles | yes |
| `/data/cache` | pixi/uv/pip/brew caches and Python `pycache` | disposable; safe to wipe |

- `/app/.venv` (the nanobot Python install) and the rest of the root filesystem
  are **ephemeral**. Changes there disappear when the container is recreated.
- `nanobot update` is disabled in the container. Upgrades happen by rebuilding
  the image with a new `NANOBOT_VERSION`.
- Put work products in `/data/config/workspace` or `/data/home`, never in `/tmp`
  or the root filesystem.

This file is documentation only: your agent context reads the workspace
`AGENTS.md`, which carries the same rules in a marked block maintained by the
image.

## Python dependencies for channels

If a channel needs an extra Python package, installing it into `/app/.venv` is
allowed and is replayed on the next start (caches live in `/data/cache`).
Persistent native/CLI tools still belong in pixi.

`NANOBOT_CHANNELS` (comma or space separated, set by the operator in `.env`)
pre-installs the Python dependencies declared by those channel manifests at
startup, before the gateway runs. Example value: `discord,telegram`. It is
useful when the WebUI cannot install them itself, for example on an air-gapped
or offline host. Enabling a channel through the WebUI already installs its
dependencies, so you normally do not need this variable.

If a name is unknown or an install fails, startup logs a `WARNING` and the
gateway still starts; re-check the name against `nanobot channels`.

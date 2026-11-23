---
name: verify-webui-app-install
description: >-
  Use when adding or checking a WebUI Apps install command (brew, npm, pip, uv),
  when an app installs but its launcher cannot find the binary, or when a cask or
  zip install fails. Verifies the install under the app runner's stripped
  environment instead of the container's.
---

# Verify a WebUI Apps install

## Core principle

The app runner starts installs with an allowlisted environment
(`nanobot/apps/cli/service.py:_subprocess_env`): `HOME`, `LANG`, `TERM`, `PATH`,
`PYTHONUNBUFFERED`, plus `XDG_RUNTIME_DIR` when set. It does not pass the image's
`HOMEBREW_*` or `npm_config_*`. A check run under the full container environment
proves nothing — it hides exactly the failure the WebUI path hits.

## Procedure

1. Classify the strategy and where its binary must land:

   | Strategy | Lands in | Survives a recreate |
   |---|---|---|
   | `brew` | `/data/brew/bin` | yes |
   | `npm -g` | `~/.local/bin` (`/data/home/.local/bin`) | yes |
   | `uv tool` | `~/.local/bin` | yes |
   | `pip` | `/app/.venv` | no (image layer) |

2. Run the install under the stripped env, with the gateway's PATH:

   ```sh
   docker compose exec -u nanobot nanobot env -i \
     HOME=/data/home LANG=C.UTF-8 TERM=dumb PYTHONUNBUFFERED=1 \
     PATH="/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
     sh -c '<install command>'
   ```

3. In the same stripped env, prove the entry point resolves and runs:

   ```sh
   ... sh -c 'command -v <entry> && <entry> --version'
   ```

4. Apply the strategy's trap:
   - **brew** — reaches the wrapper at `~/.local/bin/brew`, which restores
     `HOMEBREW_PREFIX`, `HOMEBREW_CACHE` and `HOMEBREW_NO_AUTO_UPDATE=1`.
     Casks whose artifact is a ZIP need `/usr/bin/unzip` in the image; without
     it Homebrew's sandboxed `Formula["unzip"]` lookup fails with `EACCES` on a
     cold cache.
   - **npm** — the global prefix comes from `~/.npmrc`; without it npm installs
     into `/data/pixi/envs/nodejs`, which is not on `PATH`, and the launcher's
     `which()` check fails even though the install succeeded.
   - **pip** — lands in the ephemeral venv. Durability requires the channel
     dependency replay (`NANOBOT_CHANNELS`), not this path.
5. Recreate and repeat step 3 to prove durability:

   ```sh
   docker compose up -d --force-recreate
   ```

## Common mistakes

- Running the install or the `command -v` check under the container env, or
  inside a plain `docker compose exec ... sh` without `env -i`.
- Checking only that the install command exited 0; the launcher needs `which`
  to find the entry point under the stripped env.
- Testing only a bottle formula; a cask/zip exercises a different code path.

## Origin

2026-11-23 — L-0008 (stripped env), L-0010 (casks need `unzip`), L-0006 and
L-0007 (brew is a WebUI app backend on its own volume).

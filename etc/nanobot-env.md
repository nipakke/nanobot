# nanobot environment — read this before installing tools

You are the `nanobot` user (UID/GID 1000), not root.

- There is **no `sudo`**, no passwordless escalation, and no writable root.
- **Do not run `apt`, `apt-get`, or `apk`.** System packages are fixed in the
  image. They would also be lost when the container is recreated.
- Install native/CLI tools with **pixi** instead:

  ```sh
  pixi search <term>          # find a package
  pixi info <pkg>             # inspect a package
  pixi global install <pkg>   # install a tool into /data/pixi
  pixi global list            # see installed tools
  ```

  Installed tools appear in `/data/pixi/bin`, which is first on `PATH`.

## What survives a container restart or image upgrade

| Path | Contents | Persists? |
|---|---|---|
| `/data/config` | config, sessions, memory, workspace | yes |
| `/data/home` | dotfiles, SSH/CLI config, uv tools | yes |
| `/data/pixi` | pixi global environments and tools | yes |
| `/data/cache` | pixi/uv/pip caches | disposable; safe to wipe |

- `/app/.venv` (the nanobot Python install) and the rest of the root filesystem
  are **ephemeral**. Changes there disappear when the container is recreated.
- `nanobot update` is disabled in the container. Upgrades happen by rebuilding
  the image with a new `NANOBOT_VERSION`.
- Put work products in `/data/config/workspace` or `/data/home`, never in `/tmp`
  or the root filesystem.

## Python dependencies for channels

If a channel needs an extra Python package, installing it into `/app/.venv` is
allowed and is replayed on the next start (caches live in `/data/cache`).
Persistent native/CLI tools still belong in pixi.

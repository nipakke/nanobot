# Container internals

How the image handles privileges, bind mounts, agent environment rules, and
caching under the hood.

## Privilege model

The image starts as root solely for the entrypoint's setup phase:

1. Create `/data/{config,home,pixi,brew,cache}` and establish
   `/data/home/.nanobot -> /data/config` (migrating a pre-existing directory
   into an empty `/data/config`, preserving it as `.nanobot.legacy.<timestamp>`
   when both hold data, and failing closed on wrong-target symlinks or mount
   points).
2. Fix only mismatched UID/GID entries under `/data` (no unconditional
   `chown -R`).
3. Drop privileges via `exec setpriv --reuid=nanobot --regid=nanobot --init-groups`.

Compose grants `cap_drop: [ALL]`, `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`,
and `no-new-privileges:true`. All capabilities are cleared after the drop
(`CapEff: 0000000000000000`), and there is no `sudo` or `bubblewrap`. Because
the image user is root for setup, plain `docker exec` defaults to root — always
pass `-u nanobot`.

## Bind mounts & Homebrew seeding

- An empty host folder mounted to `/data` (e.g. `/data/nanobot:/data`) or
  separate empty folders mounted to each `/data/*` path work out of the box:
  on first start, the entrypoint creates missing subtrees, sets ownership to
  `1000:1000`, and copies the baked Homebrew seed from
  `/usr/local/share/nanobot-brew-seed` into `/data/brew` without network.
- A wrapper at `~/.local/bin/brew` restores `HOMEBREW_*` defaults (including
  `HOMEBREW_NO_AUTO_UPDATE=1`) when WebUI installs run under a stripped env,
  and `~/.cache/Homebrew` links into `/data/cache/brew`.
- Never point two containers at the same data folder (concurrent startups race
  on workspace `.git` initialization and corrupt sessions).
- On Windows / Docker Desktop (9p bind mounts), heavy Homebrew installs can be
  slow or unstable; if you install large brew packages there, mount `/data/brew`
  as a Docker named volume instead.

## Agent rules & exec environment

- On startup, the entrypoint seeds missing workspace templates and maintains a
  marked block (`<!-- nanobot-image-env:begin -->` … `<!-- nanobot-image-env:end -->`)
  in `/data/config/workspace/AGENTS.md` so the agent knows the container's tool
  and persistence rules. Text outside the markers is untouched. `/etc/nanobot-env.md`
  holds the same cheat sheet for reference.
- Freshly bootstrapped configs set `tools.exec.pathPrepend` to the four image
  tool directories and `tools.exec.allowedEnvKeys` to forward `PIXI_HOME`,
  `PIXI_CACHE_DIR`, `PIXI_NO_TELEMETRY`, `XDG_CACHE_HOME`, `UV_CACHE_DIR`,
  `UV_LINK_MODE`, `PIP_CACHE_DIR`, `PYTHONPYCACHEPREFIX`, `NANOBOT_HOME`, and
  `TZ`. Existing configs created before this need both fields updated so the
  agent can see `pixi`/`npm`/`brew` tools cleanly.

## Native TUI, bytecode & `NANOBOT_HOME`

- **Native TUI:** Omitted from the default image (~123 MiB) and downloaded
  checksum-verified into `/data/config/bin/tui/<version>` on first use. Set
  `NANOBOT_TUI_NO_DOWNLOAD=1` to disable downloads (`nanobot agent --classic`
  remains available), or build locally with `BUNDLE_TUI=1` for air-gapped hosts.
- **Bytecode:** No `.pyc` files are baked into the image.
  `PYTHONPYCACHEPREFIX=/data/cache/pycache` compiles modules on first use into
  the disposable cache; the Docker healthcheck runs with `-B`.
- **`NANOBOT_HOME` and `~/.nanobot`:** `NANOBOT_HOME=/data/config` is applied
  at venv startup via `sitecustomize.py` so `nanobot status` reports
  `/data/config/config.json`, while the `~/.nanobot -> /data/config` symlink
  keeps upstream `Path.home()/.nanobot` paths inside `/data/config`.

# HANDOFF — nanobot + pixi Docker image

Date: 2026-11-23. Branch `main`. Repo is a git repo; previous good commit `0e155f0`
(image-only compose, four `/data` trees, root→setpriv, 126 acceptance checks).

This file is temporary: delete it once its items are done.

## Machine move

Nothing machine-specific travels with git. On the new host you need:

- `.env` (gitignored) — currently `NANOBOT_CHANNELS=telegram` and `EXTRA_PIXI_PACKAGES=nodejs`.
- `./data/` (gitignored) — the running instance's config, workspace, pixi envs, caches.
  The WebUI secret and the Telegram bot token live in `data/config/config.json`. Never print them.
- Docker images do **not** travel: rebuild with
  `docker compose -f compose.yaml -f compose.build.yaml build`.

## Verified in this commit

- `NANOBOT_CHANNELS` (channel-manifest dependency install at startup, uv, cached in
  `/data/cache/uv`, non-fatal on failure, env stripped before `exec`).
  Verified: 153 checks, A1–A21, twice; recreate 7 s, restart does not re-run uv,
  offline replay 2 s with `UV_OFFLINE=1`.
- `compose.bind.yaml`: `./data/{config,home,pixi,cache}` instead of named volumes.
  Verified on this host: 33 bind checks, `.nanobot` symlink survives recreate, `.ssh`
  0700 preserved (mode is emulated by Docker Desktop, not ACL-enforced).
- Acceptance-suite isolation: `scripts/smoke-compose.yaml` gives each run unique
  container names and ports. Verified: a live `nanobot` container keeps the same id
  and `StartedAt` across a full suite run.
- Two suite defects fixed (they were hiding failures, not loosening checks):
  leaked `set -e` state made A21 abort silently; `docker top -o args` needs `-o pid,args`
  on this daemon.
- node/npm/npx via `EXTRA_PIXI_PACKAGES=nodejs` → `/data/pixi`, PATH[0].
  Verified on the live instance: node 26.13.1, npm/npx 11.20.0, `npx cowsay@1.5.0`
  works, cache in `/data/home/.npm`, offline re-run after recreate, no reinstall on restart.

## Built but NOT fully verified (the reason this commit says WIP)

Homebrew baked into `/data/brew`, persisted on its own **named volume** in both modes
(`compose.yaml`), plus `npm_config_prefix=/data/home/.local`, `scripts/brew-wrapper.sh`,
`scripts/workspace-agents-env.py` (appends a marked environment block to the workspace
`AGENTS.md`), A22 in the suite.

Verified by hand on image `nanobot-pixi:brew` (1,200,167,814 B; old `0.4.2` is
1,089,052,882 B and still lacks brew):

- `brew --version`, `brew --prefix` → `/data/brew`; brew tree 82 MB, vendored portable Ruby.
- `brew install tree` and `brew install jq` worked **under the app-runner env**
  (only `HOME/LANG/TERM/PATH/PYTHONUNBUFFERED`), survived a recreate.
- `npm i -g cowsay` landed in `/data/home/.local/bin`, resolved via `command -v`.
- `AGENTS.md` block is idempotent; A1–A21 passed twice on the new image.

Not verified: **A22 end to end in the suite**. It never completed because Docker Desktop/WSL
died repeatedly on this host (exec → HTTP 500, `wsl-bootstrap` exit `0xc00000fd`, one crash
inside brew's auto-update git fetch). Treat that as host instability until disproven on
the new machine.

## Next steps (in order)

1. `bash scripts/smoke-test.sh` on the new host → A1–A22, expect 0 failures.
   If A22 fails, read `scripts/smoke-test.sh:809+` first; it uses a detached install helper
   because brew/npm print nothing for minutes.
2. Retag or rebuild `nanobot-pixi:0.4.2` from the current tree (the tag still points at
   the pre-brew image), then recreate the user stack with the bind overlay.
3. Docs gaps the agent flagged and did not finish: document `scripts/brew-wrapper.sh` in
   `README.md`, and correct the install weight — a fresh-volume `brew install` pulls
   glibc/gcc/binutils bottles (~1.1 GB), not "one small bottle".
4. Record the session lessons in `.agents/lessons/active.md` (see below).

## Hard-won constraints — do not relearn these

- `brew update` / heavy git work on a **9p bind** killed the Docker engine 2/2. Brew lives
  on a named volume on purpose. Never point `HOMEBREW_PREFIX` at `./data`.
- The WebUI app runner builds its subprocess env from scratch: `HOME`, `LANG`, `TERM`,
  `PATH`, `PYTHONUNBUFFERED` (+ `XDG_RUNTIME_DIR`). **No `HOMEBREW_*`/`npm_config_*` reaches
  `brew`/`npm`**, and `shutil.which(entry_point)` never adds a directory. Hence the wrapper
  on PATH and `/data/brew/bin` on PATH.
- `npm install -g` with no prefix writes binstubs outside PATH (`/data/pixi/envs/nodejs/bin`)
  → app looks installed and cannot run. Fixed by `npm_config_prefix=/data/home/.local`.
  `pip`-strategy apps still install into `/app/.venv` and are ephemeral by nature.
- `NANOBOT_CHANNELS` collides with nanobot's `NANOBOT_` settings prefix; the entrypoint
  unsets it and `scripts/sitecustomize.py` pops it for ad-hoc `docker exec`.
- Workspace `AGENTS.md` is injected every turn **only while it differs from the bundled
  template** (`agent/context.py:73,215-220`). `/etc/nanobot-env.md` is never read automatically.
- One container per data folder: `GitStore.init()` has no lock, so two containers on the same
  `./data` produce `GitStoreError` (`utils/gitstore.py:84-140`).
- `docker exec` defaults to root (image user is root); always `-u nanobot`.
- `core.autocrlf` is on and there is no `.gitattributes`; `*.sh` must stay LF or the image
  breaks with `bad interpreter` on a fresh Windows clone.
- The suite must never share `container_name: nanobot` with the operator stack — that mistake
  already cost one live session.

## Files

`Dockerfile`, `entrypoint.sh`, `compose.yaml`, `compose.bind.yaml`, `.env.example`,
`README.md`, `etc/nanobot-env.md`, `docs/superpowers/specs/2026-11-23-nanobot-pixi-docker-design.md`
(rev 5), `scripts/{nanobot-channels.py,workspace-agents-env.py,brew-wrapper.sh,smoke-test.sh,smoke-compose.yaml,bind-mode-check.ps1,nanobot-bootstrap.py,healthcheck.py,sitecustomize.py}`.

## Lessons to capture in `.agents/lessons/active.md`

1. Correction: brew is a **WebUI app-install backend**, not an agent tool (the agent must not
   shop with it; installs come through the Apps screen / catalog).
2. Friction/destructive: `brew update` against the 9p bind took down Docker twice.
3. Friction: the app runner's env allowlist strips `HOMEBREW_*`/`npm_config_*`; verify install
   paths with `env -i` + the five allowed variables, never with the full container env.

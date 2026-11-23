# Active lessons

## L-0001 — Four independent persistent trees; cache is disposable
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: correction
- What happened / correction: The user replaced the proposed two/three-mount layout with four explicit trees: `/data/config` (config, sessions, memory, workspace), `/data/home` (`HOME`, uv tools), `/data/pixi` (`PIXI_HOME`, global tools), and `/data/cache` (disposable XDG/pixi/uv/pip caches). Deleting `/data/cache` must never break installed tools or config; `/data/config` must survive wiping pixi or home.
- Agent did: Proposed direct mounts for nanobot data and pixi, then a three-tree non-root design with cache inside the pixi tree.
- Trigger: Docker image design for nanobot + pixi.
- Evidence: design revisions 2 and 3, `docs/superpowers/specs/2026-11-23-nanobot-pixi-docker-design.md`.

## L-0002 — Root only for volume setup, then fail-closed setpriv
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: correction
- What happened / correction: The user required the entrypoint to start as root solely to create/chown the `/data` trees and the `~/.nanobot` symlink, then drop via `setpriv --reuid=nanobot --regid=nanobot --init-groups`. No `sudo`, no fallback to root. Add `DAC_OVERRIDE` alongside `CHOWN`, `SETUID`, and `SETGID` so the ownership scan can traverse 0700 directories such as `/data/home/.ssh`; all caps are cleared after the drop.
- Agent did: Proposed a pure non-root image with no runtime chown.
- Trigger: Fresh root-owned Docker named volumes and bind-mount ownership failures.
- Evidence: design revision 3 privilege model; user correction message of 2026-11-23.

## L-0003 — Docker packaging details that must be exact
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: correction
- What happened / correction: The user corrected several implementation defaults: install `EXTRA_PIXI_PACKAGES` each in its own pixi global environment (no shared `extra`) and detect exact `$PIXI_HOME/envs/<pkg>`; use separate `NANOBOT_HEALTH_HOST_PORT` and container `NANOBOT_HEALTH_PORT`; create `/app/.venv` with `UV_PYTHON_PREFERENCE=only-system` and `--python /usr/local/bin/python3.12`; do not install `bubblewrap` under `cap_drop: ALL`; match the nanobot subcommand token so `gateway --verbose` still bootstraps; run the healthcheck with `-B`; set `PIXI_NO_TELEMETRY=1`; replace unconditional `chown -R` with a mismatched-owner `find`.
- Agent did: Used a shared `extra` pixi env, substring checks, one health port variable, uv-managed Python, bubblewrap, full-string bootstrap matching, and unconditional recursive chown.
- Trigger: Review of the Dockerfile/entrypoint/compose design.
- Evidence: user correction message of 2026-11-23; design revision 3 "Builder-check resolutions".

## L-0004 — Docker COPY followed by RUN chown -R duplicates the tree
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: friction
- What happened / correction: The first verified image was 1.67 GB. `docker history` showed a 445 MB `COPY /app/.venv` layer followed by a 445 MB `RUN chown -R nanobot:nanobot /app/.venv` layer. Replacing the pair with `COPY --chown=nanobot:nanobot --from=nanobot /app/.venv /app/.venv` preserved ownership and dropped the image to 1.09 GB.
- Agent did: Used COPY plus a separate recursive chown to satisfy the writable-venv requirement.
- Trigger: Final image-size review after the acceptance suite passed.
- Evidence: `docker history nanobot-pixi:smoke`; 1.67 GB before, 1.09 GB after.

## L-0005 — Nanobot 0.4.2 needs a sitecustomize shim for a canonical `--home`
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: friction
- What happened / correction: The `~/.nanobot -> /data/config` symlink makes file access resolve correctly, but `nanobot status` prints the symlink path `/data/home/.nanobot/config.json` because 0.4.2 has no environment-variable equivalent to the root `--home` option. A tiny venv `sitecustomize.py` calling `set_home_path($NANOBOT_HOME)` at interpreter startup makes `status` report `/data/config/config.json` while preserving an explicit `--home` override. It is documented in the README and design as the only runtime shim.
- Agent did: Relied on the symlink alone and expected the printed path to be canonical.
- Trigger: Acceptance check A9 (`nanobot status` path) failed with the symlink path.
- Evidence: `nanobot status` output; `scripts/sitecustomize.py`; design "As-built shim" note.

## L-0006 — Brew is a WebUI app-install backend, not an agent tool
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: correction
- What happened / correction: Brew exists only to serve WebUI Apps whose install command is `brew install <pkg>`; installs arrive through the Apps screen / catalog. The agent must not treat brew as a general-purpose tool and must not shop or install arbitrary packages with it.
- Agent did: Treated brew as a general tool the agent could install anything with.
- Trigger: Homebrew baked into `/data/brew` for the WebUI Apps feature.
- Evidence: HANDOFF.md "Lessons to capture" item 1; README.md:257-264 ("Homebrew" section); design spec Homebrew sections.

## L-0008 — Verify WebUI install paths under the stripped env allowlist
- Count: 1
- First: 2026-11-23
- Last: 2026-11-23
- Source: friction
- What happened / correction: nanobot's app runner (`apps/cli/service.py:_subprocess_env`) starts installs with only `HOME`, `LANG`, `TERM`, `PATH` and `PYTHONUNBUFFERED`, so no `HOMEBREW_*` or `npm_config_*` from the image reaches `brew`/`npm`. Install-path checks must run under that stripped env (`env -i` plus those five variables), never under the full container environment, which hides the failure.
- Agent did: Verified brew/npm installs under the full container environment, which masked the stripped-env failure.
- Trigger: WebUI app install path checks.
- Evidence: HANDOFF.md "Hard-won constraints" second bullet; `scripts/brew-wrapper.sh:4-13`; `entrypoint.sh:316-323`.

---
name: diagnose-agent-tool-visibility
description: >-
  Use when the agent reports a tool as missing or "command not found" although
  the container has it, when `pixi global list` is empty inside the agent, or
  when an app or tool installed successfully but the agent cannot run it.
---

# Diagnose why the agent cannot see an installed tool

## Core principle

nanobot's exec tool builds a clean child environment
(`nanobot/agent/tools/shell.py:_build_env`). On Unix it passes only `HOME`,
`LANG`, `TERM`, `PYTHONUNBUFFERED` and `allowedEnvKeys`; it does not pass `PATH`.
bash then falls back to its builtin PATH, which lacks the image tool
directories, and `pixi` cannot find its environments without `PIXI_HOME`.

## Procedure

1. Prove the tool exists for the container layer:

   ```sh
   docker compose exec -u nanobot nanobot sh -c 'command -v node'
   ```

2. Reproduce the agent's environment:

   ```sh
   docker compose exec -u nanobot nanobot env -i \
     HOME=/data/home LANG=C.UTF-8 TERM=dumb PYTHONUNBUFFERED=1 \
     bash -c 'command -v node; pixi global list'
   ```

   Empty output here, with step 1 succeeding, means the child env is the
   problem, not the install.

3. Read the two config fields in `/data/config/config.json`:
   `tools.exec.pathPrepend` and `tools.exec.allowedEnvKeys`.

4. Set `pathPrepend` to
   `/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin` and add
   `PIXI_HOME`, `PIXI_CACHE_DIR`, `PIXI_NO_TELEMETRY`, `XDG_CACHE_HOME`,
   `UV_CACHE_DIR`, `UV_LINK_MODE`, `PIP_CACHE_DIR`, `PYTHONPYCACHEPREFIX`,
   `NANOBOT_HOME`, and `TZ` to `allowedEnvKeys`. New configs get both from
   `scripts/nanobot-bootstrap.py`; an existing config needs the WebUI or a
   manual edit.

5. Verify from inside the agent-facing env: `pixi global list` shows the
   environments and `npx --version` runs.

## Do not

- Symlink the binary into `$HOME/.local/bin` to "fix" visibility: that
  directory is absent from the child's default PATH, so the symlink is still
  invisible.
- Assume the entrypoint's exported PATH applies to agent tool calls; it applies
  to the gateway process, not to the exec tool's children.

## Origin

2026-11-23 — L-0011 (the exec shell drops PATH and `PIXI_HOME`) and L-0008
(the app runner's own allowlist).

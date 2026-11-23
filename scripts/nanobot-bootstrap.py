#!/usr/bin/env python3
"""Create the nanobot config with a stable, absolute workspace path.

Runs only when the entrypoint detected that /data/config/config.json is
missing. It selects /data/config as the instance root before creating the
config, so agents.defaults.workspace is saved as /data/config/workspace
instead of a ~/.nanobot path.
"""

import json
import os
from pathlib import Path

from nanobot.cli.docker_bootstrap import initialize_config
from nanobot.config.home import set_home_path

# The exec tool builds a clean child env: it does not inherit the container
# PATH or image cache/runtime variables. Forward the non-secret layout, cache,
# telemetry, and timezone variables so agent-run tools respect the five-tree
# split instead of caching into /data/home or falling back to UTC.
EXEC_ALLOWED_ENV_KEYS = (
    "PIXI_HOME",
    "PIXI_CACHE_DIR",
    "PIXI_NO_TELEMETRY",
    "XDG_CACHE_HOME",
    "UV_CACHE_DIR",
    "UV_LINK_MODE",
    "PIP_CACHE_DIR",
    "PYTHONPYCACHEPREFIX",
    "NANOBOT_HOME",
    "TZ",
)


def _default_exec_path_prepend() -> str:
    pixi_home = os.environ.get("PIXI_HOME") or "/data/pixi"
    home = os.environ.get("HOME") or "/data/home"
    brew_prefix = os.environ.get("HOMEBREW_PREFIX") or "/data/brew"
    return f"{pixi_home}/bin:{home}/.local/bin:{brew_prefix}/bin:/app/.venv/bin"


def set_exec_defaults(path: Path) -> None:
    """Seed tools.exec defaults in a freshly created config.

    Only called for a new config: an existing one may carry the user's own
    values, so it is never rewritten.
    """
    data = json.loads(path.read_text(encoding="utf-8"))
    exec_config = data.setdefault("tools", {}).setdefault("exec", {})
    changed = False
    if not exec_config.get("pathPrepend"):
        exec_config["pathPrepend"] = _default_exec_path_prepend()
        changed = True
    allowed = exec_config.setdefault("allowedEnvKeys", [])
    for key in EXEC_ALLOWED_ENV_KEYS:
        if key not in allowed:
            allowed.append(key)
            changed = True
    if changed:
        path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )


def main() -> None:
    home = Path(os.environ.get("NANOBOT_HOME", "/data/config"))
    set_home_path(home)
    config_path = home / "config.json"
    existed = config_path.exists()
    initialize_config(config_path)
    if not existed:
        set_exec_defaults(config_path)


if __name__ == "__main__":
    main()

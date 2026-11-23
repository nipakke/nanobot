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
# PATH, and pixi needs PIXI_HOME to find the global environments.
EXEC_PATH_PREPEND = "/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin"
EXEC_ALLOWED_ENV_KEYS = ("PIXI_HOME",)


def set_exec_defaults(path: Path) -> None:
    """Seed tools.exec defaults in a freshly created config.

    Only called for a new config: an existing one may carry the user's own
    values, so it is never rewritten.
    """
    data = json.loads(path.read_text(encoding="utf-8"))
    exec_config = data.setdefault("tools", {}).setdefault("exec", {})
    changed = False
    if not exec_config.get("pathPrepend"):
        exec_config["pathPrepend"] = EXEC_PATH_PREPEND
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

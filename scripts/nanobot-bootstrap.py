#!/usr/bin/env python3
"""Create the nanobot config with a stable, absolute workspace path.

Runs only when the entrypoint detected that /data/config/config.json is
missing. It selects /data/config as the instance root before creating the
config, so agents.defaults.workspace is saved as /data/config/workspace
instead of a ~/.nanobot path.
"""

import os
from pathlib import Path

from nanobot.cli.docker_bootstrap import initialize_config
from nanobot.config.home import set_home_path


def main() -> None:
    home = Path(os.environ.get("NANOBOT_HOME", "/data/config"))
    set_home_path(home)
    initialize_config(home / "config.json")


if __name__ == "__main__":
    main()

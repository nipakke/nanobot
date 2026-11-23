"""Container shim: default every nanobot process to NANOBOT_HOME.

The image exposes NANOBOT_HOME=/data/config, but nanobot 0.4.2 has no
environment-variable equivalent for its root `--home` option. The
/data/home/.nanobot symlink makes default CLI calls resolve to the same files,
yet `nanobot status` would print the symlink path. Selecting /data/config here
keeps the reported config path and the resolved file identical.

Python imports this module automatically at interpreter startup from the venv's
site-packages directory. It is intentionally tiny and fail-open: if nanobot is
not importable (for example during a dependency install), it does nothing.
"""

import os

try:
    from pathlib import Path

    from nanobot.config.home import set_home_path
except Exception:  # pragma: no cover - only during partial installs
    pass
else:
    _home = os.environ.get("NANOBOT_HOME")
    if _home:
        try:
            set_home_path(Path(_home))
        except Exception:  # pragma: no cover - never break interpreter startup
            pass

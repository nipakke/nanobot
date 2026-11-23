"""Container shim: canonical home and a clean nanobot environment.

Two image-level helpers run here at venv interpreter startup:

1. NANOBOT_HOME is selected as nanobot's home. The image exposes
   NANOBOT_HOME=/data/config, but upstream nanobot has no environment-variable
   equivalent for its root `--home` option. The /data/home/.nanobot symlink
   makes default CLI calls resolve to the same files, yet `nanobot status`
   would print the symlink path. Selecting /data/config here keeps the
   reported config path and the resolved file identical.
2. NANOBOT_CHANNELS is removed from the environment. It is this image's
   entrypoint knob, but nanobot's settings use the NANOBOT_ prefix, where
   NANOBOT_CHANNELS would be parsed as the whole channels mapping (and any
   value, even empty, fails validation). The entrypoint reads the value and
   unsets it before exec; this drop covers ad-hoc `docker exec ... nanobot ...`
   processes, which inherit the container env.

Python imports this module automatically at interpreter startup from the venv's
site-packages directory. It is intentionally tiny and fail-open: if nanobot is
not importable (for example during a dependency install), it does nothing.
"""

import os

os.environ.pop("NANOBOT_CHANNELS", None)

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

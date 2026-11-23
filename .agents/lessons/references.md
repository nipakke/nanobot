# Repo references

Pointers to read before certain work. Add the topic, the pointer, and "read before <when>". Never copy the referenced content.

- **nanobot's `Path.home()/".nanobot"` paths** — `nanobot/data_access.py` (update/data locks), `installation_lock.py`, `bun.py` (tool cache), `channels/qq/runtime.py` (media) and `gateway/runtime.py:_default_config_path` build paths from `Path.home()` and ignore `set_home_path()`. The `$HOME/.nanobot` symlink is what keeps that state inside `/data/config`; without it a real `/data/home/.nanobot/updates/data-locks` appears. Read before changing how nanobot's instance root is selected. (L-0012)

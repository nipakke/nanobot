#!/usr/bin/env python3
"""Install the Python dependencies of the channels named in NANOBOT_CHANNELS.

Runs in the entrypoint's unprivileged phase with /app/.venv/bin/python. Names
are resolved against nanobot's own channel registry, so the declared
requirements come from each channel's manifest rather than from a duplicated
list here. Satisfied requirements are detected from installed distribution
metadata; only missing ones reach uv, in a single invocation. Wheels land in
/data/cache/uv, so a recreated container replays the install from disk.

Never fails the container: every problem is logged as a warning and the
gateway still starts.
"""

from __future__ import annotations

import importlib
import os
import shlex
import subprocess
import sys

PREFIX = "[channels]"
VENV_PYTHON = "/app/.venv/bin/python"
INSTALL_TIMEOUT_SECONDS = 600


def log(message: str) -> None:
    print(f"{PREFIX} {message}", flush=True)


def warn(message: str) -> None:
    print(f"{PREFIX} WARNING: {message}", file=sys.stderr, flush=True)


def split_names(raw: str) -> list[str]:
    """Split NANOBOT_CHANNELS on commas and whitespace, preserving order."""
    names: list[str] = []
    for part in raw.replace(",", " ").split():
        if part not in names:
            names.append(part)
    return names


def last_line(text: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def install(targets: list[tuple[str, list[str]]]) -> bool:
    """Install every requirement for all targets with one uv invocation."""
    from nanobot.optional_features import extra_installed, install_args_for_extra

    install_args: list[str] = []
    names: list[str] = []
    for name, dependencies in targets:
        args, _label = install_args_for_extra(name, dependencies)
        install_args.extend(args)
        names.append(name)

    if not install_args:
        log("channels " + ", ".join(names) + " declare no installable requirements")
        return True

    command = ["uv", "pip", "install", "--python", VENV_PYTHON, *install_args]
    log("installing channel dependencies for: " + ", ".join(names))

    env = os.environ.copy()
    env["UV_CACHE_DIR"] = env.get("UV_CACHE_DIR") or "/data/cache/uv"
    env["UV_LINK_MODE"] = "copy"
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=INSTALL_TIMEOUT_SECONDS,
            env=env,
        )
    except Exception as exc:  # noqa: BLE001 - startup must not depend on uv
        warn(f"channel dependency install could not run: {exc}")
        return False

    if proc.returncode != 0:
        warn(f"channel dependency install failed (uv exited {proc.returncode})")
        detail = (proc.stderr or proc.stdout or "").strip()
        for line in detail.splitlines()[-12:]:
            warn(line)
        warn("retry with: " + shlex.join(command))
        return False

    importlib.invalidate_caches()
    missing = [name for name, deps in targets if not extra_installed(name, deps)]
    if missing:
        warn("uv reported success but these channels still miss requirements: " + ", ".join(missing))
        warn("retry with: " + shlex.join(command))
        return False

    summary = last_line(proc.stdout) or last_line(proc.stderr)
    log("installed channel dependencies for: " + ", ".join(names))
    if summary:
        log("uv: " + summary)
    return True


def main() -> int:
    # The entrypoint passes the list as an argument: the venv's sitecustomize
    # shim removes NANOBOT_CHANNELS from the environment before this module is
    # imported (see scripts/sitecustomize.py for why).
    requested = split_names(" ".join(sys.argv[1:]))
    if not requested:
        return 0

    try:
        from nanobot.channels.registry import discover_plugins
        from nanobot.optional_features import extra_installed
    except Exception as exc:  # noqa: BLE001 - startup must not depend on nanobot internals
        warn(f"cannot resolve NANOBOT_CHANNELS inside the nanobot venv: {exc}")
        return 0

    try:
        plugins = discover_plugins()
    except Exception as exc:  # noqa: BLE001 - startup must not depend on discovery
        warn(f"cannot discover nanobot channels: {exc}")
        return 0

    unknown = [name for name in requested if name not in plugins]
    if unknown:
        warn("unknown channel(s) in NANOBOT_CHANNELS: " + ", ".join(unknown))
        warn("known channels: " + ", ".join(sorted(plugins)))
        warn("use a name from that list (see `nanobot channels` for details)")

    targets: list[tuple[str, list[str]]] = []
    for name in requested:
        plugin = plugins.get(name)
        if plugin is None:
            continue
        dependencies = list(plugin.dependencies)
        if not dependencies:
            log(f"channel '{name}' declares no Python dependencies")
            continue
        if extra_installed(name, dependencies):
            log(f"channel dependencies for '{name}' already installed")
            continue
        targets.append((name, dependencies))

    if not targets:
        return 0

    try:
        install(targets)
    except Exception as exc:  # noqa: BLE001 - startup must not depend on the install path
        warn(f"channel dependency install aborted: {exc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

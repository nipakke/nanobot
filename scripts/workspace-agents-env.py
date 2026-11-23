#!/usr/bin/env python3
"""Keep a marked environment-rules block inside the workspace AGENTS.md.

nanobot only injects the workspace's own ``AGENTS.md``/``SOUL.md``/``USER.md``
into the agent context (``nanobot/agent/context.py``), and it skips a file while
it still equals the bundled template (``_SKIPPABLE_DEFAULTS``). ``/etc/
nanobot-env.md`` is documentation for humans: nothing reads it automatically.
The rules about this image therefore have to live in the file the agent reads.

The block is delimited by HTML comment markers so the entrypoint can update it
in place on every start without touching anything the user wrote. On a fresh
instance the workspace files do not exist yet: nanobot creates them from its own
bundled templates inside the gateway, i.e. after the entrypoint has run. With
``--seed-templates`` this helper calls nanobot's own ``sync_workspace_templates``
first (the exact function the gateway calls, which creates only missing files and
never overwrites), so the block is in place before the first agent turn. Without
the flag a missing ``AGENTS.md`` is left alone: inventing one here would bypass
nanobot's template logic.
"""

from __future__ import annotations

import sys
from pathlib import Path

BEGIN = "<!-- nanobot-image-env:begin -->"
END = "<!-- nanobot-image-env:end -->"
SEED_FLAG = "--seed-templates"

BODY = (
    "## Container environment (maintained by the image)",
    "",
    "These rules describe the image you run in; they win over generic advice.",
    "",
    "- No `sudo`, and no `apt`/`apt-get`/`apk`: you are an unprivileged user and",
    "  the system packages are fixed in the image.",
    "- Install native/CLI tools with `pixi global install <pkg>`. They land in",
    "  `/data/pixi` and survive restarts, recreates and image upgrades.",
    "- Install JS tools with `npx <pkg>` (cache in `$HOME/.npm`) or",
    "  `npm i -g <pkg>`, whose binaries land in `~/.local/bin` (on `PATH`).",
    "- Homebrew lives at `/data/brew` (its own volume) solely for WebUI Apps",
    "  whose install command uses `brew` (binaries land in `/data/brew/bin`, on",
    "  `PATH`). Do not use `brew` for ad-hoc tool installs; use",
    "  `pixi global install <pkg>` instead.",
    "- `/app/.venv` is ephemeral: anything pip-installed there is gone after a",
    "  recreate. Channel dependencies are the exception, replayed at startup.",
    "- `nanobot update` is rejected by design; upgrades come from an image",
    "  rebuild (`NANOBOT_VERSION`).",
    "- Persists: `/data/config` (config, sessions, memory, workspace),",
    "  `/data/home` (`HOME`, `~/.local`), `/data/pixi` (pixi tools) and",
    "  `/data/brew` (brew). `/data/cache` is disposable; the rest of the",
    "  filesystem is ephemeral, so keep work products in `/data/config/workspace`",
    "  or `/data/home`.",
)


def _eol(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def render(text: str) -> str:
    """Return ``text`` with exactly one up-to-date marked block."""
    eol = _eol(text)
    block = eol.join((BEGIN, *BODY, END))

    start = text.find(BEGIN)
    if start == -1:
        if text and not text.endswith(("\n", "\r")):
            text += eol
        separator = eol if text else ""
        return text + separator + block + eol

    end = text.find(END, start)
    if end == -1:
        raise ValueError("unterminated block marker")
    end += len(END)
    return text[:start] + block + text[end:]


def seed_templates(workspace: Path) -> None:
    """Create the workspace files nanobot's gateway would create on start."""
    try:
        from nanobot.utils.helpers import sync_workspace_templates
    except Exception as exc:  # keep the entrypoint independent of import order
        print(f"[agents-md] WARNING: templates unavailable: {exc}", file=sys.stderr)
        return
    try:
        added = sync_workspace_templates(workspace, silent=True)
    except Exception as exc:
        print(f"[agents-md] WARNING: workspace template sync failed: {exc}", file=sys.stderr)
        return
    if added:
        print(f"[agents-md] seeded {len(added)} workspace file(s) from nanobot's templates")


def main(argv: list[str]) -> int:
    seed = SEED_FLAG in argv[1:]
    operands = [arg for arg in argv[1:] if arg != SEED_FLAG]
    if len(operands) != 1:
        print(
            f"usage: workspace-agents-env.py [{SEED_FLAG}] <workspace-dir>",
            file=sys.stderr,
        )
        return 2

    workspace = Path(operands[0])
    if seed:
        workspace.mkdir(parents=True, exist_ok=True)
        seed_templates(workspace)

    target = workspace / "AGENTS.md"
    if not target.is_file():
        print(f"[agents-md] {target} does not exist; leaving it to nanobot")
        return 0

    # surrogateescape keeps the round-trip byte-exact for anything we do not
    # rewrite, so an unchanged file is never touched at all.
    original = target.read_bytes().decode("utf-8", "surrogateescape")
    try:
        updated = render(original)
    except ValueError:
        print(
            f"[agents-md] WARNING: {target} has {BEGIN} without {END}; left unchanged",
            file=sys.stderr,
        )
        return 0

    if updated == original:
        print(f"[agents-md] {target}: environment block already current")
        return 0

    target.write_bytes(updated.encode("utf-8", "surrogateescape"))
    print(f"[agents-md] {target}: environment block written")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

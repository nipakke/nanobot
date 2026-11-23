# Repo rules

Durable preferences and rules promoted from `.agents/lessons/active.md`.

- **Brew lives at `/data/brew` on the `nanobot_brew` named volume, never on the `./data` 9p bind.** Never point `HOMEBREW_PREFIX`, `HOMEBREW_REPOSITORY` or `HOMEBREW_CELLAR` at `./data`: `brew update` and heavy git work there killed the Docker engine twice (`docker exec` -> HTTP 500, WSL bootstrap `0xc00000fd`). (L-0007)

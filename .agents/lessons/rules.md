# Repo rules

Durable preferences and rules promoted from `.agents/lessons/active.md`.

- **Avoid heavy Homebrew write churn on Windows/Docker Desktop 9p bind mounts.** `brew update` and heavy git work on a Windows `./data` 9p bind killed the Docker engine twice (`docker exec` -> HTTP 500, WSL bootstrap `0xc00000fd`). The image ships a `nanobot-brew` wrapper (`HOMEBREW_NO_AUTO_UPDATE=1`) and seeds `/data/brew` from `/usr/local/share/nanobot-brew-seed` on first boot so single `/data` bind mounts work on Linux; on Windows/Docker Desktop, keep `/data/brew` on a named volume when running heavy brew installs (and `scripts/smoke-compose.yml` uses isolated named volumes). (L-0007)

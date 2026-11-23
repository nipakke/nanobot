# nanobot Docker

Unofficial Docker image for [nanobot](https://github.com/HKUDS/nanobot)
(`nanobot-ai`) running as a non-root `nanobot` user with `pixi` for runtime
tools, Homebrew for WebUI Apps, and persistent storage under `/data`.

Images (`linux/amd64`) are built automatically via GitHub Actions on new stable
`nanobot-ai` releases and monthly maintenance updates, and published to
`docker.io/nipakke/nanobot` as `latest`, `<version>`, and
`<version>-<YYYYMMDD>-<shortsha>`.

## Compose

```yaml
name: nanobot

services:
  nanobot:
    image: nipakke/nanobot:latest
    container_name: nanobot
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      # Leave empty to generate a random WebUI password in the startup logs
      NANOBOT_WEB_TOKEN: ""
      TZ: UTC
      # Optional: CLI tools installed via pixi on startup
      # EXTRA_PIXI_PACKAGES: "jq,ripgrep"
      # Optional: channels to pre-install on startup (e.g. discord,telegram,slack)
      # NANOBOT_CHANNELS: "discord,telegram"
    ports:
      - "8765:8765"
      - "127.0.0.1:18790:18790"
    volumes:
      # Single host directory for everything under /data:
      - ./data:/data
      # Or mount the five trees separately (comment out ./data:/data above):
      # - ./data/config:/data/config
      # - ./data/home:/data/home
      # - ./data/pixi:/data/pixi
      # - ./data/brew:/data/brew
      # - ./data/cache:/data/cache
    healthcheck:
      test: ["CMD", "/usr/local/bin/python3", "-I", "-B", "/usr/local/bin/healthcheck.py"]
      interval: 30s
      timeout: 5s
      start_period: 45s
      retries: 3
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - DAC_OVERRIDE
      - SETUID
      - SETGID
    security_opt:
      - no-new-privileges:true
```

- **CLI tools (`EXTRA_PIXI_PACKAGES`):** The agent can install CLI tools
  persistently via `pixi`, or you can pre-install them on startup with
  `EXTRA_PIXI_PACKAGES: "jq,ripgrep"`.
- **Channels (`NANOBOT_CHANNELS`):** Messaging channels (Discord, Telegram,
  Slack, etc.) need extra packages installed into nanobot itself, which the
  agent cannot install persistently. Set `NANOBOT_CHANNELS: "discord,telegram"`
  so the container installs and keeps them ready across recreates (see
  [available channel names](docs/configuration.md#channels-nanobot_channels)).
- **Tailnet-only access (Tailscale):** the commented block in
  [`compose.yml`](compose.yml) replaces published ports with a
  `tailscale/tailscale` sidecar; see [Tailscale sidecar](docs/tailscale.md).

## Documentation

- [Configuration, channels & tools](docs/configuration.md) — env vars, channel list, `pixi`, Homebrew/WebUI Apps
- [Usage, backups & upgrades](docs/usage.md) — common commands, `/data` layout, backups, resets, upgrading
- [Container internals](docs/internals.md) — privilege model, bind mounts, agent rules, TUI & caching
- [Local builds & development](docs/development.md) — building locally, smoke tests, CI & Renovate
- [Tailscale sidecar](docs/tailscale.md) — tailnet-only access, no published host ports
- Upstream: [HKUDS/nanobot](https://github.com/HKUDS/nanobot) · [nanobot-ai on PyPI](https://pypi.org/project/nanobot-ai/)

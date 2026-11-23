# Configuration, channels & tools

## Environment variables

See [`.env.example`](../.env.example) for a template:

| Variable | Default | Description |
|---|---|---|
| `NANOBOT_IMAGE` | `nipakke/nanobot:latest` | Image tag (`latest`, `<version>`, or immutable `<version>-<YYYYMMDD>-<shortsha>`) |
| `NANOBOT_WEB_TOKEN` | _(random)_ | Initial WebUI password (applied only when creating `config.json`) |
| `TZ` | `UTC` | Container timezone (e.g. `Europe/Budapest`) |
| `EXTRA_PIXI_PACKAGES` | _(empty)_ | Comma/space-separated `pixi` packages installed on startup (e.g. `jq,ripgrep`) |
| `NANOBOT_CHANNELS` | _(empty)_ | Comma/space-separated channel names pre-installed on startup (see below) |

Container ports are fixed (`8765` for WebUI, `18790` for `/health`). Change the
host side directly in `compose.yml` under `ports:` (for example
`127.0.0.1:8765:8765` to restrict the WebUI to localhost).

## Channels (`NANOBOT_CHANNELS`)

Messaging channels need extra packages installed into nanobot itself. Because
`/app/.venv` is replaced on every container recreate or upgrade, set
`NANOBOT_CHANNELS` (comma or space separated, e.g. `discord,telegram,slack`) so
the container installs them on startup and replays them from `/data/cache/uv`
across recreates. Unknown names or install failures log a warning and never
block startup.

Built-in channel names:

`dingtalk`, `discord`, `email`, `feishu`, `linear`, `matrix`, `mattermost`,
`mochat`, `msteams`, `napcat`, `qq`, `signal`, `slack`, `telegram`, `websocket`,
`wecom`, `weixin`, `whatsapp`, `whatsapp_agent`

Check the exact list in your running version:

```sh
docker compose exec -u nanobot nanobot nanobot channels
```

## Runtime tools & WebUI Apps

`PATH` starts with `/data/pixi/bin:/data/home/.local/bin:/data/brew/bin:/app/.venv/bin`.

- **`pixi` (CLI/native tools):** Use `pixi search <term>`,
  `pixi global install <pkg>`, and `pixi global list`. `EXTRA_PIXI_PACKAGES`
  installs each package into its own isolated env (`/data/pixi/envs/<pkg>`) on
  startup and skips already-installed ones on restart. Failures warn without
  blocking startup.
- **Homebrew (WebUI Apps):** Seeded into `/data/brew` from the image on first
  start (no network needed) with `HOMEBREW_NO_AUTO_UPDATE=1` and `/usr/bin/unzip`
  for zip casks. Reserved for WebUI Apps — use `pixi` for ad-hoc CLI installs.
- **`npm` / `npx`:** Configured via `~/.npmrc` so `npm install -g` lands in
  `/data/home/.local/bin` and persists across recreates.

| WebUI App strategy | Lands in | Survives recreate / upgrade |
|---|---|---|
| `brew` | `/data/brew` | Yes |
| `npm -g` | `/data/home/.local/bin` + `~/.npm` | Yes |
| `uv tool` | `/data/home/.local` | Yes |
| `pip` | `/app/.venv` | No (ephemeral image layer) |

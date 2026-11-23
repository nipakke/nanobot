# Tailscale sidecar

`compose.yml` includes an optional, commented-out Tailscale sidecar. Enable it
to reach nanobot over your tailnet instead of published host ports. Nothing is
required for the default stack.

## How it works

nanobot joins the sidecar's network namespace (`network_mode: service:tailscale`)
and keeps binding `8765` (WebUI) and `18790` (`/health`) as usual. With the
`ports:` block gone, nothing is published on the host or LAN; both endpoints are
reached over the tailnet, for the devices your ACLs allow.

## Prerequisites

- A Tailscale account and an auth key; prefer a tagged, non-expiring key scoped
  to one tag so it can be revoked on its own.
- `/dev/net/tun` visible to the Docker daemon; without it this example does not
  work (see below).
- Optional: MagicDNS enabled, so the node answers at
  `http://nanobot.<tailnet>.ts.net:8765` instead of a `100.x` address.

## Enabling

1. Add the key to `.env` (never commit it):

   ```sh
   TS_AUTHKEY=tskey-auth-...
   ```

2. Comment out the `ports:` block in `compose.yml` — published ports conflict
   with the shared network namespace.
3. Uncomment `network_mode: service:tailscale` and `depends_on: [tailscale]` in
   the `nanobot` service.
4. Uncomment the `tailscale` service and the top-level `volumes:` entry.
5. Start and check the node:

   ```sh
   docker compose up -d
   docker compose exec tailscale tailscale status
   ```

Open the WebUI at `http://<node>:8765` (the MagicDNS name or the `100.x`
address) and log in with `NANOBOT_WEB_TOKEN`, which still applies. `/health`
moves to `http://<node>:18790/health`. `TS_AUTHKEY` is required by the sidecar
service, so Compose refuses to start it while the key is unset.

## Lifecycle

- The sidecar owns the network namespace, so recreating it also recreates
  nanobot.
- Login state lives on the `tailscale-state` named volume and survives
  recreates. `docker compose down -v` removes it, so the next start needs the
  key again.
- To upgrade, pull and recreate as usual: `docker compose pull`, then
  `docker compose up -d`.

## Docker Desktop / WSL2

If `/dev/net/tun` is missing, the sidecar can only run in userspace mode
(`TS_USERSPACE=true`), which exposes SOCKS5/HTTP proxy listeners instead of a
real interface. This transparent example does not work that way; run it on a
Linux host.

## HTTPS with `tailscale serve`

For a certificate on the MagicDNS name, enable HTTPS in the tailnet admin
console and proxy the WebUI through the sidecar:

```sh
docker compose exec tailscale tailscale serve --bg 8765
```

`--bg` stores the config in tailscaled's state on the volume and resumes after
restarts; to declare it instead, mount a `serve.json` and set `TS_SERVE_CONFIG`.

## Security

Your tailnet ACLs are the boundary. With no published ports, the WebUI, the
gateway and `/health` are reachable from any tailnet device the ACLs permit, so
keep the grant narrow (one tag, one user, or one group). The WebUI token still
guards the UI; tailnet membership alone is not a substitute for it.

---
name: verify-image-without-host-ports
description: >-
  Use when the smoke test suite cannot start because Docker cannot publish a
  host port (Docker Desktop/WSL2 `/forwards/expose returned unexpected status:
  500`, excluded port ranges), or when a behavioral check is needed without
  disturbing a live stack.
---

# Verify the image without publishing host ports

## Core principle

The entrypoint, persistence, config and agent-rules behavior can all be checked
through `docker exec` and the container-side healthcheck. Publishing a port is
only needed by the suite's Compose `--wait` gate and its host-side HTTP checks,
so a host with broken port forwarding can still verify everything else.

## Procedure

```sh
IMAGE=nanobot-pixi:verify
docker build -t "$IMAGE" .

P="nanobot-verify-$$"
for v in config home pixi cache; do docker volume create "${P}_$v"; done
docker run -d --name "$P" \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE \
  --cap-add SETUID --cap-add SETGID --security-opt no-new-privileges:true \
  -v "${P}_config:/data/config" -v "${P}_home:/data/home" \
  -v "${P}_pixi:/data/pixi" -v "${P}_cache:/data/cache" \
  -e NANOBOT_WEB_TOKEN=verify-token "$IMAGE"

# Wait for the gateway via the container-side check, not a host port.
for _ in $(seq 1 60); do
  docker exec -u nanobot "$P" \
    /usr/local/bin/python3 -I -B /usr/local/bin/healthcheck.py && break
  sleep 2
done
```

Then check, all through `docker exec`:

- volumes adopted: `/data/config` and `/data/home` owned by `1000:1000`;
- the instance root: `nanobot status` names `/data/config/config.json` (this is
  the entrypoint-bypassed path, so it proves the shim alone works);
- `/data/home/.nanobot` resolves to `/data/config`;
- the workspace `AGENTS.md` block is present exactly once;
- config bootstrap: `/data/config/config.json` exists with
  `agents.defaults.workspace` at `/data/config/workspace`.

Entrypoint edge cases run the full entrypoint with `/bin/true` instead of the
gateway (seed a volume first, then run with the same caps and `-v` mounts), e.g.
a pre-existing `~/.nanobot` symlink or directory.

Clean up only what you created:

```sh
docker rm -f "$P"
for v in config home pixi cache; do docker volume rm "${P}_$v"; done
```

## Boundaries

- Does not exercise host-port mapping, Compose `--wait`, or the host-side
  `/health` URL. Startup port-binding and host HTTP checks still need real ports.
- Does not replace `bash scripts/smoke-test.sh`. Run the suite once Docker can
  publish ports again; this mode is for when it cannot.

## Origin

2026-11-23 — L-0013 (Docker Desktop forwarded-port 500 during smoke test startup; 17 of 18
targeted checks still ran this way).

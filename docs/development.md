# Development

Local builds, smoke tests, CI workflows, and automated release setup.

## Local builds

`compose.build.yml` overlays `compose.yml` to build locally under
`${NANOBOT_BUILD_IMAGE:-nanobot-pixi:local}` so local builds never shadow the
published `nipakke/nanobot` image:

```sh
docker compose -f compose.yml -f compose.build.yml up -d --build
```

All version pins live in [`Dockerfile`](../Dockerfile) (`NANOBOT_VERSION`,
`PIXI_VERSION`, `BREW_VERSION` + `BREW_COMMIT`, and digest-pinned `FROM` lines).
`compose.build.yml` forwards pin args only when explicitly set in the
environment:

```sh
# Build a specific nanobot version locally
NANOBOT_BUILD_IMAGE=nanobot-pixi:0.5.0 NANOBOT_VERSION=0.5.0 \
  docker compose -f compose.yml -f compose.build.yml build

# Offline/air-gapped build keeping the ~123 MiB native TUI binary
BUNDLE_TUI=1 docker compose -f compose.yml -f compose.build.yml build

# Multi-arch build (published images are linux/amd64 for now)
docker buildx build --platform linux/amd64,linux/arm64 .
```

Other build args: `UID=1000`, `GID=1000`. `BREW_VERSION` and `BREW_COMMIT` are
verified against each other at build time; bump both together.

## Smoke tests

[`scripts/smoke-test.sh`](../scripts/smoke-test.sh) builds the image (or tests
an existing one) and runs end-to-end checks in an isolated Compose project
(`nanobot-smoke-<pid>`) with its own container name, volumes, network, and host
ports (defaults `18766` web, `18791` health):

```sh
bash scripts/smoke-test.sh
```

Useful overrides:

- `NANOBOT_SMOKE_IMAGE=<ref> NANOBOT_SMOKE_SKIP_BUILD=1` — test a prebuilt image.
- `NANOBOT_SMOKE_WEB_PORT=<port> NANOBOT_SMOKE_HEALTH_PORT=<port>` — pick free
  host ports (helpful on Windows hosts with excluded port ranges).
- `NANOBOT_SMOKE_BREW_FORMULA=jq` — test the larger `jq` bottle dependency chain
  (~1.1 GB) instead of the default small `tree` bottle.

Expected `nanobot`, `pixi`, and `Homebrew` versions are read from the
`Dockerfile` `ARG` defaults. Cleanup removes only resources created by that run.

## CI workflows and Renovate

Two separate workflows keep pull requests isolated from registry secrets:

- [`.github/workflows/test.yml`](../.github/workflows/test.yml) — runs on
  `pull_request` only with zero secrets. Builds the image and runs
  `scripts/smoke-test.sh`. Require this `test` check on `main`.
- [`.github/workflows/publish.yml`](../.github/workflows/publish.yml) — runs on
  `push` to `main` when image files change (`Dockerfile`, `entrypoint.sh`,
  `.dockerignore`, `scripts/**` excluding `smoke-*`, `etc/**`), or on
  `workflow_dispatch`. Builds, runs `scripts/smoke-test.sh`, tags `latest`,
  `<version>`, and `<version>-<YYYYMMDD>-<shortsha>`, and pushes that exact
  tested image.

> **Dry-run state:** The Docker Hub login and `docker push` steps in
> `.github/workflows/publish.yml` are commented out until the Docker Hub repo
> and secrets are configured.

[`renovate.json`](../renovate.json) tracks `Dockerfile` pins, base image
digests, and GitHub Actions (stable releases only, 2-day `minimumReleaseAge`):

- `nanobot-ai`: every stable release (including majors) opens a PR immediately
  and auto-merges on green `test`.
- Base image digests, `pixi`, Homebrew, and GitHub Actions (minor/patch/digest):
  batched into one `monthly maintenance` PR on the 1st of each month,
  auto-merged on green `test`. Base images stay on their `3.12`/`bookworm` line.
- Major updates of non-`nanobot-ai` dependencies: separate PRs awaiting manual
  approval.

### One-time GitHub & Docker Hub setup

1. Create `nipakke/nanobot` on Docker Hub with a Read & Write access token
   scoped to that repository.
2. Add GitHub repo secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.
3. Install the **Renovate** GitHub App on the repository.
4. Enable **Allow auto-merge** in GitHub Settings → General.
5. Protect `main` with a ruleset requiring the `test` status check.
6. Uncomment the login and push steps in `.github/workflows/publish.yml`.

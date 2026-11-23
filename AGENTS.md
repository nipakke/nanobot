# nanobot

Design-stage repo. The single source of truth is `docs/superpowers/specs/2026-11-23-nanobot-pixi-docker-design.md` (Revision 3); read it before any implementation work.
The implementation plan is `docs/superpowers/plans/2026-11-23-nanobot-pixi-docker.md`; use it task-by-task: it cites the design doc as its spec.

## Status

- No source code, README, Dockerfile, Compose file, package manifest, CI, tests, or linter/formatter config exists yet. Never document build/test/lint commands as if they exist.
- The design's `Status:` line gates implementation and must be checked before coding (currently `awaiting approval`).
- New designs go in `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`.

## Image under design (not built)

- Debian-based image running `nanobot-ai==0.4.2` with pixi; glibc is required, so no Alpine base.
- pixi is the only supported way to install runtime native/CLI tools. No runtime `apt`/`apk`, no `sudo`, no setuid helpers.
- Root entrypoint exists only for setup, then `setpriv` drops to `nanobot` (UID/GID 1000). Caps: drop `ALL`, add only `CHOWN`, `DAC_OVERRIDE`, `SETUID`, `SETGID`, plus `no-new-privileges`.
- The image user is root, so every `docker exec` must pass `-u nanobot`; plain `docker exec` can create root-owned files in `/data`. This is a Docker constraint, not a preference.
- In-container `nanobot update` is rejected by design; upgrades are backup-gated image rebuilds via `NANOBOT_VERSION`.

## Persistence

- Four trees: `/data/config` (config, sessions, memory, workspace), `/data/home` (`HOME`), `/data/pixi` (pixi global envs), `/data/cache` (100% disposable).
- `/data/home/.nanobot` is a symlink to `/data/config`; wiping `/data/cache` must never break installed tools or config.
- Never mount a volume over `/app/.venv`; it is ephemeral and changes only with `NANOBOT_VERSION` or the image tag.
- `NANOBOT_HOME` is an image-level helper variable, not upstream nanobot; 0.4.2 has no env-var equivalent to `--home`.
- The healthcheck uses container-side `NANOBOT_HEALTH_PORT` (default 18790); `NANOBOT_HEALTH_HOST_PORT` moves only the host-published port.
- Planned, not yet created: local builds use `docker compose -f compose.yaml -f compose.build.yaml up -d --build`.

<!-- lesson-learning -->
## Lessons
Committed lesson log: `.agents/lessons/`. Load the `lesson-learning` skill before any non-trivial task, the moment the user corrects or rejects your approach (`no`, `don't`, `stop`, `again`, `I said`), and the moment a command, test, or build fails unexpectedly or repeats. Do not wait to be asked. Recurring lessons become repo rules, references, or skills; never write lessons to global skills. Sync with `/learn-sync`.

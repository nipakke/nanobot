# nanobot

Docker image and Compose stack for `nanobot-ai==0.4.2` with pixi-managed runtime tools, Homebrew for WebUI Apps, and a non-root `nanobot` user.

## Where things live

- `README.md` — authoritative user docs; read before changing behavior.
- `docs/superpowers/specs/2026-11-23-nanobot-pixi-docker-design.md` — design, Revision 5, implemented and verified (177 acceptance checks A1–A22).
- `.agents/references/` — durable project facts, e.g. `nanobot-image.md` for the image's layout and constraints.
- `.agents/skills/` — repo procedures; load the matching skill before the task.
- `.agents/lessons/` — the committed lesson log.

Do not grow this file: add durable detail under `.agents/`.

<!-- lesson-learning -->
## Lessons
Load the `lesson-learning` skill before non-trivial work and on any correction or unexpected failure; `active.md` and `promoted.md` record what to apply and what to capture.

---
name: lesson-learning
description: >-
  Load this skill before any non-trivial task in this repository. Load it the moment the user corrects or rejects your approach (any "no", "don't", "stop", "again", "I said", or pointed correction), the moment a command, test, build, or tool fails unexpectedly or the same failure recurs, the moment you work around a limitation, and the moment you redo work. Do not wait to be asked. Check existing lessons before acting; capture corrections and friction; promote recurring lessons into this repo's own rules, references, or skills.
---

<!-- lesson-learning-template: version=3 sha256=bcec06840ea5aa253891a4a0bdc7a620535b35280d1d9be3099d612a3761b446 -->

# lesson-learning

This is a repo-local loop. The log is `.agents/lessons/`, committed on purpose. This skill writes only the artifacts that `.agents/lessons/config.md` names in this repo. Never write to `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills`, or any global skill source.

## Before work

Before starting a non-trivial task, read `.agents/lessons/active.md` and `.agents/lessons/promoted.md`, plus the rules and references files named in `.agents/lessons/config.md`.

Match entries by file path, command, technology, or symptom. If a lesson applies, apply it and say which lesson you are applying. If a lesson says stop or never, stop. If nothing matches, proceed.

## Capture

Capture on two triggers:

1. **User correction or rejection.** Any "no", "don't", "stop", "again", "I said", or pointed correction of how you worked.
2. **Self-observed friction.** An unexpected command, test, build, or tool failure; the same failure twice; a required workaround; rework; or a mismatch between documentation and reality.

Do not capture typos, one-off factual fixes, expected TDD red, or transient errors unless they recur.

Before writing, read `.agents/lessons/active.md`, `.agents/lessons/promoted.md`, `.agents/lessons/rejected.md`, and `.agents/lessons/config.md`. Match semantically, not by string: the same underlying lesson often shares no words. If a promoted artifact already covers it, point to it instead of re-capturing. If a rejected proposal covers it, say so and do not re-propose it without new evidence.

**Match an existing entry.** Increment `Count`, update `Last`, and add one occurrence line with the source and the evidence.

**New entry.** Append the next `L-nnnn` number to `.agents/lessons/active.md`:

```md
## L-0001 — <short title>
- Count: 1
- First: YYYY-MM-DD
- Last: YYYY-MM-DD
- Source: correction | friction
- What happened / correction: <close to the user's words, or the failure and what it blocked>
- Agent did: <what you had done>
- Trigger: <file, command, PR, or task that surfaced it>
- Evidence: <error text, command, diff, or file:line>
```

No classification at capture.

## Promote

Promote automatically, without asking, when an entry reaches its threshold:

- Safety or destructive lesson: `Count: 1`.
- Reference pointer: `Count: 1`.
- Preference or rule: `Count: 2`.
- Procedure: `Count: 3`.

Choose the container from `.agents/lessons/config.md`. Paths are relative to the repo root; `none` disables a target.

- **Rule** — append it to the rules target.
- **Reference** — append the topic, a pointer (path or URL), and "read before <when>" to the references target. Never copy the referenced content.
- **Procedure** — append it to the skills target if that is not `none`; otherwise append it to the procedures target.

For a skill, follow the repo's existing skill conventions. Load the `writing-skills` skill if it is available. Include a short `## Origin` section with the date and the lesson IDs.

After promoting, record one line in `.agents/lessons/promoted.md` (`YYYY-MM-DD — <lesson> — <artifact>`), remove the entry from `.agents/lessons/active.md`, and do not renumber other entries. In your final report, say what you promoted and where.

**Rejection.** If the user rejects a promotion, remove the artifact, record it in `.agents/lessons/rejected.md` with the date, reason, and trigger, and do not re-propose it without new evidence.

## Scope

Repo only. A lesson learned here becomes a repo artifact only. If it looks universal, say so and leave the decision to the user. Never write to `~/.config/opencode/skills`, `~/.claude/skills`, `~/.agents/skills`, or any other global skill source.

## The log

`.agents/lessons/` is committed, never ignored:

- `config.md` — container paths: `rules`, `references`, `procedures`, `skills`. Edit it when the repo's structure differs.
- `active.md` — full entries; read before work and before capture.
- `promoted.md` — one-line index of promoted artifacts; read before work and before capture.
- `rejected.md` — rejected proposals; read before capture.
- the rules file and references file named in `config.md`.
- the procedures directory named in `config.md`, created only when a procedure is promoted there.

Keep `active.md` append-only except for `Count`, `Last`, occurrence lines, and promotion removal. Never delete `rejected.md` entries.

# AGENTS.md

<!-- antislop:start -->
## antislop
For UI, copy, people, mobile layout, or code comments work, read `DESIGN.md` for direction first, then the antislop core and the skill for the task:

- Core: `~/.agents/skills/antislop/SKILL.md`
- UI / visual: `~/.agents/skills/antislop-ui/SKILL.md`
- Copy & text: `~/.agents/skills/antislop-copywriting/SKILL.md`
- People: `~/.agents/skills/antislop-human/SKILL.md`
- Mobile / responsive: `~/.agents/skills/antislop-layoutmobile/SKILL.md`
- Code comments: `~/.agents/skills/antislop-code/SKILL.md`

Before starting, ask the user when antislop applies: during the work, or after it is done.
Standing answer for this project: DURING. UI and copy work follows the rules while it is
written and ends with the core file's Delivery Gate as a PASS/FAIL report.
<!-- antislop:end -->

Always update the changelog after any changes!

## Working in this checkout

More than one session can be editing this repository at the same time. These rules keep concurrent
work from destroying itself; they come from a day of parallel agent work that lost about two hours
to exactly the failures listed here.

- **Check who else is writing before you change anything.** `git status`, recent file mtimes, and
  a plain question to the owner settle it in seconds. Never `git checkout`/`restore`/`revert` a
  file you did not write, and never "clean up" an unfamiliar refactor: a half-applied change is
  usually a live session mid-edit, not abandoned work. If shared code blocks the build, ask or
  wait; do not finish another session's design by guessing.
- **One build lane.** SwiftPM shares one module cache, so concurrent `swift build`/`swift test`
  runs crash the compiler with `error: fatalError` and burn hours. When agents or a person share
  a checkout, exactly one process builds and tests; everyone else validates with
  `xcrun swiftc -parse <files>` and queues its suite runs. A single serial full-suite pass is
  both faster and more trustworthy than parallel filtered runs.
- **Leave a progress note.** Append one line to a scratch file after each completed step: what is
  done, what is next. An interrupted turn then resumes in seconds instead of re-reading
  everything, and a successor can pick up the exact spot. If the files you edit are not
  tracked, make that clear in the report.
- **Size work to one turn.** A task that needs hours of tool use will be cut off mid-way. Split it
  into steps that finish and can be verified independently, and hand back a small, reviewable
  diff.
- **Report evidence, pending work included.** When a shared file blocks verification, return the
  parse-level or type-check evidence you do have and list the suite commands that remain to run.
  A named, pending verification is useful; a claimed green run that never happened is not.


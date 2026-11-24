# AGENTS.md

Hisingen is a native macOS menu bar app built with SwiftUI and AppKit. These rules apply across the repository.

## Before editing

- Confirm the repository root, branch, and working tree with `git rev-parse --show-toplevel`, `git status --short --branch`, `git diff`, and `git diff --cached`. Read any nested `AGENTS.md` files that cover the files you’ll touch.
- Read the relevant README, build scripts, package or project configuration, and CI workflow before choosing commands. Follow the toolchain, deployment targets, and checks declared there. Use the source and existing tests to confirm behavior before changing it.
- Identify the files likely to change. Inspect existing changes and recent modification times on those paths. If another writer appears to be touching the same files or owns a change you depend on, confirm ownership before editing the overlap. Continue on independent work while waiting.

## Task checklist and status

- Evaluate the request before implementation. Identify the intended outcome, acceptance criteria, current behavior, affected components, unknowns, and dependencies. Resolve uncertainties that affect the implementation through source review, existing tests, or focused investigation.
- Break the work into subtasks with one verifiable result each. Identify prerequisites and shared files so you can start independent work in parallel and order dependent work. Keep separate checklists for features on separate branches. For a small change, keep the checklist short.
- Include implementation steps, tests or manual checks, the changelog fragment, and the final feature review where applicable. Track CI and merge as separate items when they are part of the task.
- Keep one current checklist in the task plan, issue, PR, or shared scratch note. For collaborative work, record an owner and any prerequisite for each subtask where they are known. Mark work **Ready** when its prerequisites are satisfied, **In progress** when claimed, or **Blocked** with the reason and next action. Check off each item when its result is verified and record the evidence.
- Update the checklist when scope changes or review finds follow-up work. Reopen an item if later changes invalidate its result. Share the current checklist or a link to it at progress checkpoints and handoff so the user can see what is done and what is next.

Use the steps that fit the task, with a separate item for each independently verifiable piece of implementation.

- [ ] Confirm acceptance criteria and current behavior.
- [ ] Implement each scoped change and check it through its normal entry point.
- [ ] Run the relevant tests and manual checks.
- [ ] Add a `changelog.d/` fragment and update any affected documentation.
- [ ] Complete the final feature review and resolve its findings.
- [ ] Verify required CI on the version being merged.
- [ ] Merge the feature PR when authorized.

## Agent coordination

- The agent handling the request is the lead. It owns the checklist, dependencies, overall progress, and final feature review. Assign each delegated subtask to one owner. The lead decides when to spawn additional agents based on the work, available tools, and the user's constraints.
- Delegate when independent work can proceed safely or a focused second review would help. Good candidates include source investigation, test or fixture work with separate ownership, implementation in a separate component, and read-only review. Do small or tightly coupled work in one session. If delegation is unavailable, keep executing the subtasks in dependency order.
- When assigning work, give the agent the goal, acceptance criteria, base commit, worktree or branch, files it may edit, dependencies, and expected checks. Agree who owns shared files such as the changelog, package manifest, or common tests. Give parallel writers separate worktrees and task branches from the agreed feature commit. Integrate their work into the feature branch in dependency order.
- Use direct agent messages for discoveries, blockers, changes to shared contracts, requested handoffs, and completion. Agents should tell the lead as soon as a finding affects another task. Coordinate ownership changes with affected agents before starting an overlapping edit. Record decisions and their impact in the shared checklist or task notes.
- A completion report gives the outcome, changed paths, branch or commit, exact checks and results, and remaining risks or blockers. The lead reviews the diff before integration and verifies the assembled feature on its branch. Coordinate compiler-driven checks through the shared build lane.

## Keep work moving and resume safely

- Work through the ready subtasks until the requested outcome is verified or no authorized work can proceed. When a subtask is blocked, record the dependency or failure and start another ready item. Diagnose failures and try a specific recovery when there is evidence it can help. Surface an unresolved blocker with the exact decision or input needed.
- For work that spans sessions, keep the latest checklist and checkpoint somewhere the next session can access, such as the existing issue, draft PR, or shared workspace. Record the feature branch and base or head commit, active owners and worktrees, verified results, and the next ready item. Keep credentials and private data out of shared notes.
- At the start of a resumed session, read the checkpoint, compare it with the actual branch and working-tree state, and check for active owners before touching their work. Confirm which checks still apply to the current revision. Pick up the next ready item and reopen any result that later changes invalidated.

## Feature branches and merges

- **Every new feature gets its own branch and pull request.** Start from the current `origin/main`, or the agreed integration branch if the maintainer specifies one. Keep `main` for integration and keep unrelated features out of the same branch, even when one request covers several features.
- Use a separate Git worktree for each feature being developed concurrently. Check `git worktree list` and the branch before editing. Leave an active checkout on its current branch. If a feature is already in progress, continue on its existing branch.
- Keep the feature, its tests, relevant documentation, and changelog entry together. Stage the intended paths and review the full diff against the PR base before handing it off.
- When two features need the same change, give the shared prerequisite its own reviewable branch. Merge it first, then update the dependent branches from the target branch and re-run the affected checks. Record the merge order in the PRs.
- Merge feature PRs one at a time after the final feature review and required CI checks pass on the version being merged. Refresh a branch when intervening changes affect its behavior or introduce conflicts. Preserve both changes when resolving changelog conflicts. Follow the repository's merge rules and keep the pending PR ready for the maintainer when merge authorization is outside the task.

## Working in a shared checkout

- Treat all pre-existing staged, unstaged, and untracked changes as someone else’s work unless ownership is clear. Preserve those changes and their staging state. Keep unrelated refactors, formatting, generated files, and dependency or lockfile changes out of the diff.
- Re-read a shared file immediately before patching it, including the changelog. If its contents changed after you read it, inspect the new diff and patch only a clearly independent hunk. Coordinate with the other writer if the edits overlap or affect the same behavior.
- Never use reset, clean, stash, restore, checkout, or revert to get someone else’s changes out of your way. If their work blocks a build, record the failing check and continue with verification that can run independently.
- After each completed step, append one line to the task notes with what is done and what is next. Keep scratch notes outside the tracked diff and use the shared checklist for cross-session status.

## Repository map

| Path | Use |
| --- | --- |
| `Sources/Hisingen/` | macOS app source. Start with `UI/`, `Domain/`, or the relevant service under `Services/`. |
| `Sources/Hisingen/Resources/`, `Resources/` | App strings and assets, plus bundle metadata and packaging resources. |
| `Tests/HisingenTests/` | Swift tests and sanitized provider fixtures. |
| `Scripts/`, `Makefile`, `.github/workflows/` | Build, validation, CI, and packaging entry points. |
| `site/`, `home-assistant/` | Separate website and Home Assistant integration surfaces. Check their own instructions when changing them. |
| `docs/development/repository-layout.md`, `docs/README.md` | Detailed layout and links to architecture, domain, and operations docs. |

## Implementation

- Make the smallest change that works through the normal app entry point. Reuse the existing architecture and components. Preserve behavior for existing callers and saved data unless the task changes it.
- For changes to persisted settings, credentials, or data formats, account for upgrades from existing installations. For async, lifecycle, or stateful changes, check cancellation, retries, duplicate actions, and partial failures where they apply.
- Follow existing patterns for UI state, async work, error handling, and logging. Keep credentials, tokens, signing material, and private user data out of source, fixtures, diagnostics, and scratch notes. Use mocks or sanitized fixtures for external integrations. Keep live, state-changing smoke tests within the scope the user authorized.
- Keep dependency, platform target, permission, entitlement, signing, and distribution changes tied to an explicit task requirement. Use the existing scripts for generated files and change their inputs when needed.
- Keep provider-specific payloads and decoding in the provider layer. Preserve the capability and authorization checks for remote actions across entry points. Represent missing vehicle readings as unknown and keep tests deterministic with sanitized fixtures or mocks.
- Keep generated credential sources (`GeneratedVolvoSecrets.swift` and `GeneratedPolestarSecrets.swift`), local `.env` files, diagnostics exports, `.build*/`, and `releases/` out of commits. Use fixture configuration for credential-free validation and the documented generator when updating build configuration.
- Record every change that a user or developer would notice as a fragment in `changelog.d/` (see its README): one file per change, `<slug>.<added|changed|fixed|removed|security>.md`, holding one bullet in the existing style. Release preparation moves fragments into the new version's section of `CHANGELOG.md`. A release that is already prepared keeps taking entries directly in its `CHANGELOG.md` section. Preserve other entries, and run `python3 Scripts/changelog.py check`.

<!-- antislop:start -->
## Antislop

Apply antislop **during** the work. This is the standing project decision.

For UI, copy, depictions of people, mobile layout, or code comments, read `DESIGN.md` first, then the core file and each skill that applies.

| Work | Skill file |
| --- | --- |
| Core | `~/.agents/skills/antislop/SKILL.md` |
| UI and visuals | `~/.agents/skills/antislop-ui/SKILL.md` |
| Copy and text | `~/.agents/skills/antislop-copywriting/SKILL.md` |
| People | `~/.agents/skills/antislop-human/SKILL.md` |
| Mobile and responsive layout | `~/.agents/skills/antislop-layoutmobile/SKILL.md` |
| Code comments | `~/.agents/skills/antislop-code/SKILL.md` |

For applicable work, run the core file’s Delivery Gate and report PASS or FAIL with any failed checks. If a required file is missing, identify it and mark the gate unverified. For UI changes, exercise the affected flow on the target platform where available, including relevant keyboard and accessibility behavior, appearance, window or menu sizing, and empty, loading, or error states.
<!-- antislop:end -->

## Build and verification

### Shared build lane

- Run one compiler-driven build or test at a time across sessions sharing a checkout or cache. Wrap the command in the lane script from any worktree of this repository: `sh Scripts/build-lane.sh run --wait 1800 -- <command>`. It claims `hisingen-build-lane` in the shared Git directory (`git rev-parse --path-format=absolute --git-common-dir`), runs the command, and releases the claim when the command ends, however it ends. `sh Scripts/build-lane.sh status` shows who holds it.
- The claim records the wrapper's and the command's process IDs. A claim whose processes are gone is reclaimed by the next caller, so a crashed session does not hold the lane. Queue with `--wait SECONDS`; without it a busy lane fails at once with exit 75.
- A claim with no process ID was written by hand or by another tool, and the script never reclaims it. Confirm with its owner, or that its recorded process and children have stopped, before you remove the directory yourself. Leave active processes and their build state alone.
- While the lane is occupied, use source review or `xcrun swiftc -parse <files>` on a Mac.

### Toolchain and commands

Hisingen targets macOS 15 and later on Apple Silicon and Intel. `Package.swift` declares Swift tools 6.0 and Swift 6 language mode. Use full Xcode for the CI-equivalent build. The documented hosted pin is Xcode 26.3, with `.github/ci-toolchain.json` authoritative for the checked-out branch. Run `make doctor` to check the selected compiler, SDK, and SwiftPM.

Run commands from the repository root. See `docs/operations/build.md` and `docs/operations/ci.md` for the current options.

| Goal | Command |
| --- | --- |
| Build the native binary | `make build` |
| Run deterministic tests serially | `HISINGEN_BUILD_CONFIGURATION=fixture sh Scripts/test.sh --skip Live --no-parallel` |
| Run a focused deterministic suite | Add `--filter <suite>` to the deterministic command. |
| Run portable lint and repository checks | `sh Scripts/ci-checks.sh portable` |
| Check localization or documentation links | `python3 Scripts/check-localization.py` or `python3 Scripts/check-docs-links.py` |
| Run local CI against the working tree | `make ci` |
| Validate the committed snapshot | `sh Scripts/ci-local.sh --committed` |
| Launch the development app | `make run` |
| Exercise bundle-dependent behavior | `make app IDENTITY=- NOTARIZE=never`, then `open releases/Hisingen.app` with the default output directory. |

### Verification and evidence

- Record whether you parsed, type-checked, built, ran tests, or exercised the app. Each verifies a different part of the change. Keep live tests opt-in and separate from ordinary validation.
- For code changes, run the relevant existing tests and verify the affected behavior through its normal entry point where practical. Add a focused regression test when existing tests would miss the bug. Run the full suite serially when shared code or broad behavior changes warrant it, or when the repository requires it.
- Verify platform-specific behavior on the supported platform. A Linux or syntax-only check leaves AppKit, signing, and runtime behavior pending. For docs-only changes, review the diff and check affected links, paths, and commands where practical.
- Before handoff, run `git diff --check` and, for your staged changes, `git diff --cached --check`. Review the final working-tree and staged diffs against the baseline. Check that all intended files are present, including untracked files that belong in the review, and that the changelog is updated.

## Final feature review

- After implementation, review the complete feature diff against its target branch and the acceptance criteria. Trace each criterion through the actual app or integration entry point and record the test, manual check, or code evidence that verifies it. Exercise interactive behavior on the supported platform when it is necessary to verify the feature.
- Check the normal flow, relevant failure and edge cases, regressions in existing behavior, and any upgrade path the change affects. Include permissions, privacy, accessibility, localization, or cleanup when the feature touches them. Confirm the PR contains the intended scope and that its tests, docs, and changelog are included where applicable.
- Add each blocking finding to the checklist, fix it, then re-review the affected code and rerun the relevant checks. Review the latest revision before marking it ready to merge. Report **PASS** when every required criterion has evidence, **FAIL** for an unmet criterion, or **BLOCKED** when required verification cannot run. Leave unfinished items open and state exactly what is needed to close them.

## Handoff and release

- Report changed behavior and files, the final checklist status, the exact checks run and their results, and any unrelated failures you could establish. For blocked or skipped checks, include why they remain pending and the command or manual steps needed to finish them.
- Identify any untracked deliverables or artifacts required to reproduce the result. Keep scratch files and generated build products out of the patch unless they’re explicit deliverables.
- Follow `docs/operations/releases.md` and the release workflows on the target branch for versioning, signing, notarization, and distribution. Keep release preparation and release tags out of feature branches. Start release work from the merged commit as directed by the runbook.
- Commit, push, merge, tag, or publish within the scope the user requested. When release work is in scope, report artifact and updater verification separately from the local app run.

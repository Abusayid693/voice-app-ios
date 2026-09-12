---
name: release
description: Cut a new version — finalize CHANGELOG.md's Unreleased section into a dated version entry and bump the app version in project.yml. Use when the user asks to release, cut a version, or bump the version number.
argument-hint: "[patch|minor|major|X.Y.Z, or leave blank to be asked]"
---

Cuts a new release: finalizes `CHANGELOG.md` and bumps the version in `local-tts/native-ios/project.yml`. This repo has exactly one source of truth for the version — `project.yml`'s `info.properties.CFBundleShortVersionString` — no other file mirrors it.

## 1. Make sure everything recent is actually logged

Read `CHANGELOG.md`. If there's an `## [Unreleased]` section, check it reflects what's actually shipped since the last version — if something significant from this conversation or recent commits (`git log --oneline -10`, `git status --short`) isn't in there yet, add it first. Match the existing entries' style: one concise, user-facing line per change (what shipped, not why it was built that way — this file tracks *what*; `docs/adr/` tracks *why*, so don't let an entry balloon into a decision writeup). If there's no `[Unreleased]` section at all and nothing pending to log, that's fine — proceed with an empty one.

## 2. Decide the new version number

Read the current version from `project.yml`. Then:
- If the argument is an explicit bump type (`patch`/`minor`/`major`) or a literal version (`X.Y.Z`), use that directly.
- Otherwise, suggest a bump based on what's in `[Unreleased]`: `### Added` entries present → suggest **minor**; only `### Fixed`/`### Changed`/`### Removed` → suggest **patch**. State the suggestion and the resulting version number, and confirm with the user before proceeding rather than silently picking — a version bump isn't something to guess on.

## 3. Update `project.yml`

Set `CFBundleShortVersionString` to the new version.

## 4. Finalize the changelog

Rename `## [Unreleased]` to `## [X.Y.Z] - <today's date>`. Insert a fresh empty `## [Unreleased]` above it, ready for the next round of work.

## 5. Regenerate and verify signing

`project.yml` changed, so per this repo's standing discipline (`CLAUDE.md`): run `xcodegen generate` from `local-tts/native-ios/`, then `grep -n DEVELOPMENT_TEAM KokoroAneTest.xcodeproj/project.pbxproj` and confirm both entries still match `project.yml`'s team. Flag it plainly if they don't — don't silently fix it without saying so.

## 6. Commit the release — scoped, so it's traceable to this exact version

This is the one exception to this repo's usual "don't auto-commit" rule: a release needs a single, identifiable commit so `git log`/`git blame` can always answer "which commit is version X.Y.Z" (and so a tag or GitHub Release can point at it later). Commit **only** the files this skill itself touched:
```
git add local-tts/native-ios/project.yml local-tts/native-ios/KokoroAneTest.xcodeproj/project.pbxproj CHANGELOG.md
git commit -m "Release vX.Y.Z

<one line per changed area from the finalized changelog section>"
```
The version number must be in the commit's first line (`Release vX.Y.Z`), not buried in the body, so it's readable straight from `git log --oneline`.

**Don't** `git add -A` or otherwise sweep in unrelated pending work — if `git status` shows other dirty files beyond those three, stop and ask whether they belong in this release commit or should be committed separately first; never silently fold unrelated changes into a release commit.

Don't create a git tag and don't push — those stay explicit user-requested actions. Report the new version, the commit hash, and what's in the release notes; mention the tag command (`git tag vX.Y.Z`) as something they can run, without running it yourself.

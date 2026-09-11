---
name: issue-only
description: File a GitHub issue for a feature or bug, without opening a PR. Use when the user wants to just create/file an issue, not start work on a branch.
argument-hint: "[short description of the feature or bug]"
---

Given a short description of a feature or bug (from the argument passed to this skill, or from what's already been discussed in this conversation), file a GitHub issue with the `gh` CLI. This repo is `Abusayid693/voice-app-ios`.

1. **Decide the type**: a feature/enhancement request, or a bug report.
2. **Draft the issue** matching the shape of this repo's templates:
   - Feature (`.github/ISSUE_TEMPLATE/feature_request.yml`): `## What problem does this solve?` / `## Proposed solution` / `## Alternatives considered` (if any) / `## Additional context` (if any).
   - Bug (`.github/ISSUE_TEMPLATE/bug_report.yml`): what happened, steps to reproduce, expected behavior, device/iOS version/engine/voice if relevant, logs if available.
   If the description given is vague, ask the user to confirm scope before creating it — don't invent requirements or repro details that weren't discussed.
3. **Create it**: `gh issue create --title "..." --body "..." --label enhancement` (or `--label bug`).
4. **Report back** the issue URL.

Don't create a branch, make code changes, or open a PR as part of this skill — it only files the issue. Use `/issue-and-pr` instead if the user wants both.

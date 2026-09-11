---
name: issue-and-pr
description: Create a GitHub issue for a feature or fix, then open a PR that closes it. Use when the user asks to file an issue and open/create a PR for work that's done or in progress.
argument-hint: "[short description of the feature or fix]"
---

Given a short description of a feature or fix (from the argument passed to this skill, or from what's already been discussed/built in this conversation), do the following using the `gh` CLI. This repo is `Abusayid693/voice-app-ios`; the base branch is `main`.

1. **Draft the issue.** Write a clear title and a body with "What problem does this solve?" / "Proposed solution" / "Additional context" sections, matching the shape of `.github/ISSUE_TEMPLATE/feature_request.yml` (for a feature) or `bug_report.yml` (for a fix). If the description given is vague, ask the user to confirm scope before creating it — don't invent requirements that weren't discussed.
2. **Create the issue**: `gh issue create --title "..." --body "..." --label enhancement` (or `bug` for a fix). Capture the issue number from the returned URL.
3. **Confirm the branch.** If the work isn't already on its own feature branch (check `git branch --show-current`), create one off `main` and make sure all relevant changes are committed there.
4. **Push and open the PR**: push the branch, then `gh pr create --base main --head <branch> --title "..." --body "..."`. The PR body should include:
   - A `## Summary` section (bullet points of what changed)
   - `Closes #<issue-number>` so merging auto-closes the issue
   - A `## Test plan` checklist of what to verify (manual steps, since this is an iOS app with no automated test suite currently)
5. **Report back** both URLs (issue + PR) to the user.

Don't push to `main` directly or merge the PR as part of this skill — it only files the issue and opens the PR for review.

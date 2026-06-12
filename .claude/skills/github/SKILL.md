---
name: github
description: Manages GitHub issues, epics, sub-issues, pull requests, labels, project board, and all gh CLI interactions. Use when creating issues, filing bugs, listing or viewing issues, managing epics, viewing or updating the project board, setting labels or priority, adding sub-issues, creating or reviewing PRs, running any gh command, or any interaction with GitHub.
allowed-tools: Bash(gh *), Bash(git *)
---

Repository: `nimling/samna-migrate` | Organization: `nimling`
Project Board: #15 | Project ID: `PVT_kwDOA6RKQc4AvdjO`

## Deprecated Flags — Never Use

- `gh issue create --project "..."` — fatal deprecation error
- `gh issue edit --add-project / --remove-project` — fatal deprecation error
- `--type` flag on `gh issue create` or `gh issue edit` — does not exist

Use `gh project item-add` for the board and GraphQL `updateIssue` for issue type.

## Issue Creation Flow

1. `gh issue create --repo nimling/samna-migrate --title "..." --body "..." --label "<label>"`
2. Get node ID: `gh api graphql -f query='{ repository(owner:"nimling",name:"samna-migrate") { issue(number:<N>) { id } } }' -q '.data.repository.issue.id'`
3. Set type via `updateIssue` GraphQL mutation using the node ID and a type ID below
4. If parent epic exists: find epic node ID, then `addSubIssue` mutation
5. `gh project item-add 15 --owner nimling --url <ISSUE_URL> --format json -q '.id'`
6. Optionally set status via `gh project item-edit`

## IDs

**Issue Types**
- Task: `IT_kwDOA6RKQc4AtgRd`
- Bug: `IT_kwDOA6RKQc4AtgRf`
- Feature: `IT_kwDOA6RKQc4AtgRi`
- Epic: `IT_kwDOA6RKQc4B3ZL8`

**Status** (`PVTSSF_lADOA6RKQc4AvdjOzgl4sv0`): Backlog `740c3937` · Todo `f75ad846` · In Progress `47fc9ee4` · Blocked `52040dd3` · Staging `ed3cdcc1` · Done `98236657`

## Commit Messages

Single line: `closes #<number>: <short description>` or `updates #<number>: <short description>`

Use `closes` when the commit fully resolves the issue, `updates` when it is partial work. No type prefix, no icons, no `Co-Authored-By`, max 72 chars.

## PR Format

```
gh pr create --repo nimling/samna-migrate --title "..." --body "$(cat <<'EOF'
## Summary
<bullet points>

Closes #<number>
EOF
)"
```

No test plan, no checklist, no footer, no AI attribution.

## Output Format

After any create, update, close, list, or PR operation:

| # | Title | Link |
|---|-------|------|

## Rules

- Always set labels and type on every issue and PR
- Never create new labels
- Never create a PR or push without explicit user consent
- No icons, emojis, or AI attribution anywhere
- All git operations use the current system git user identity

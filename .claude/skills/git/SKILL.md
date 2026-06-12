---
name: git
description: Performs local git operations including committing, pushing, branching, merging, diffing, stashing, and checking status. Use when committing changes, pushing code, creating branches, viewing diffs, checking git status, merging branches, or any local version control workflow.
argument-hint: [commit|branch|push|status|diff|log|merge|stash|...] [args]
allowed-tools: Bash(git *)
---

Repository: `nimling/samna-migrate`

## Branch Naming

- Bug fix: `fix/{slug}`
- Feature: `feat/{slug}`
- With issue: `fix/{number}-{slug}` or `feat/{number}-{slug}`

Slugs are lowercase, hyphen-separated, max 5 words.

## Commit Messages

Single line: `closes #<number>: <short description>` or `updates #<number>: <short description>`

Use `closes` when the commit fully resolves the issue, `updates` when it is partial work. No type prefix, no icons, no `Co-Authored-By`, max 72 chars.

Always run `git status` and `git diff --cached` before committing. Show the draft message to the user before committing.

## Rules

- Never force push, push to main/master, or run destructive commands without explicit user consent
- Never use `--no-verify` or `--amend` unless explicitly asked
- Always commit as the current system git user

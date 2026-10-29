---
name: deploy
description: Releases the smig cli. Tests, builds, checks the schema chain, commits, pushes and tags through sbump so the Go module tag, the action.yml pin and the locally installed binary stay in sync. Use when the user says deploy, release or ship in this repo, or asks for a patch, minor or major release of smig. Not for running the tests alone, which is the test skill, not for upgrading consumer ledgers after the release, which is the smig skill, and not for the sbump flags themselves, which is the sbump skill.
argument-hint: [patch|minor|major]
allowed-tools: Bash(just *), Bash(git *)
---

The release of `github.com/nimling/samna-migrate`, in order, stopping on the first failure with the error verbatim. It needs a git repository with an `origin` remote. Tests are the `test` skill; the standing rules are `.claude/rules/deploy.md`; what consumers do after it is `~/.claude/rules/migrations.md`.

## 1. Tests for the change

1. Read the change with `git diff` and `git status` and name its observable surface.
2. Pure logic gets a `_test.go` beside the code, a postgres path a case under `test/integration/`, cli behaviour a case under `test/e2e/`. Trivial moves and rename only diffs need none.
3. Anything that changes a command's exit behaviour, a ledger write, a preflight or reconcile verdict, or a `samna_migrate` schema step is covered, asserting the observable contract, not the call graph.

## 2. Test and build

1. `just test`, as the `test` skill describes; it needs docker. Failure: report the failing names and stop. No commit, no bump.
2. `just build` writes `bin/smig` with the version ldflags. Failure: report the build output and stop.

## 3. Schema chain

1. A diff under `internal/upgrade/sql/` adds `upgrade_to_<n>.sql`, wires it into the `//go:embed` list and the switch in `internal/upgrade/upgrade.go`, and bumps `SchemaVersion` in `pkg/cli/version.go`. Any one missing bricks every consumer's boot check; stop and say which.
2. A `SchemaVersion` bump is at least a minor.

## 4. Embedded skill

1. `.claude/skills/smig` ships inside the binary through `skill.go`; a change to a command, a flag or a verdict updates it in the same release: `.claude/rules/deploy.md` Skill.

## 5. Commit and push

1. Stage the files of the release by name with `git add <files>`, never another session's work. When the tree holds changes that are not the release, release from a clean clone, because `sbump` refuses a dirty tree.
2. `git commit -m "<one line>"` describing the user visible change, `#<number>: <description>` when an issue covers it.
3. `git push` on the current branch.

## 6. Bump and tag

1. Patch: `just deploy`, which runs `sbump patch --env APP_VERSION --yaml ./action.yml@.inputs.smig-version.default --push-version --auto --workflow`: `APP_VERSION` and the `smig-version` default in `action.yml` together, the tag, the push and the workflow track.
2. Minor or major: `just deploy minor` or `just deploy major`.
3. The tag runs `.github/workflows/build-publish-action.yml`; the `latest` tag moves only after a green build, so a failed release leaves consumers on the previous version: `.claude/rules/stream.md` 5. Success is that run green.
4. Consumers pick it up through `go get github.com/nimling/samna-migrate@vX.Y.Z` and the `action.yml` pin on their runners. Every consumer ledger is then behind and `up` refuses until `smig upgrade` runs: `~/.claude/rules/migrations.md` 4.

## 7. Install locally

1. `just install` builds `bin/smig` and installs it as `GOPATH/bin/smig`, so the local binary matches the tag that shipped.

## Never

1. Skip step 2. A missing test, a failing test or a failing build blocks the release.
2. Hand edit `APP_VERSION` in `.env` or the `smig-version` default in `action.yml`; `sbump` owns both.
3. Tag or push tags by hand; `just deploy` is the one tagging path.
4. Use `--no-verify` or `--no-gpg-sign`.
5. Ship a `samna_migrate` schema step without its `SchemaVersion` bump.
6. Build a release binary with `go build`; `just build` injects the version ldflags.

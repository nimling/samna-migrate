---
paths:
  - "internal/migrate/**"
  - "internal/apply/**"
  - "internal/log/**"
  - ".github/workflows/**"
  - "action.yml"
---

# The smig mcp, its steps and private modules

The cross repo rule is `../.claude/rules/stream.md`; this file names what is smig's own.

1. `smig mcp` is `internal/migrate/mcp.go`, `cli.MCPCommand` from `nimbody/cli`, serving every command but `mcp`, `skill`, `plugin`, `completion`, `help` and `version`, each annotated read, write or destructive; the run page is `ui://smig/run`.
2. Steps come from `internal/apply/apply.go` `File`: one step per applied file, id the file path, `running` before `d.RunFile`, `done` with the duration or `failed` with the error after. Reported only under a tool run, `stream.Machine()`, because smig prints its own progress through `internal/log` in a terminal.
3. nimbody is private and `samna-migrate` is public, so the org secret does not reach it: the repo carries `DOCKER_PACKAGE_READ` itself. `.github/workflows/build-publish-action.yml` exposes it as `GH_REPO_TOKEN` to `git config --global url."https://${GH_REPO_TOKEN}@github.com/".insteadOf` with `GOPRIVATE=github.com/nimling/*` at the workflow level, in the `test` and `build` jobs.
4. `action.yml` installs smig with `go install ...@v<version>` on the consumer's runner, so its `Install smig` step runs the same `git config` when `GH_REPO_TOKEN` is set in the caller's env; samna_auth and bookable pass `GH_REPO_TOKEN: ${{ secrets.DOCKER_PACKAGE_READ }}` on the step. A consumer that forgets it fails at `go install`.
5. `just deploy` runs `sbump` with `--auto` and moves `.inputs.smig-version.default` in `action.yml`; the `latest` tag moves only after a green build, so a failed release leaves consumers on the previous version.

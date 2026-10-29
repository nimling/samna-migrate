---
paths:
  - "internal/migrate/**"
  - "internal/apply/**"
  - "internal/log/**"
  - ".github/workflows/**"
  - "action.yml"
---

# The smig mcp, its steps and private modules

The cross repo rule is `~/.claude/rules/stream.md`; this file names what is smig's own. What the server serves and how its steps report: `.nimpress/mcp.md`. Why the private module needs its own token and how the `latest` tag follows a release: `.nimpress/release.md`.

1. `smig mcp` is `internal/migrate/mcp.go` on `cli.MCPCommand` from `nimbody/cli`. Every tool is annotated read, write or destructive; the run page is `ui://smig/run`.
2. Steps come from `internal/apply/apply.go` `File`: `running` before `d.RunFile`, `done` or `failed` after. Report them only under `stream.Machine()`; in a terminal smig prints its own progress through `internal/log`.
3. The repo carries `DOCKER_PACKAGE_READ` itself. `.github/workflows/build-publish-action.yml` exposes it as `GH_REPO_TOKEN` to `git config --global url."https://${GH_REPO_TOKEN}@github.com/".insteadOf` with `GOPRIVATE=github.com/nimling/*` at the workflow level, in the `test` and `build` jobs.
4. `action.yml` `Install smig` runs the same `git config` when `GH_REPO_TOKEN` is set in the caller's env, then downloads `smig-<os>-<arch>` from the GitHub release of `v<smig-version>` with `curl` and puts it on `GITHUB_PATH`; there is no `go install` on the runner. A consumer that pulls a private git include through `migrate.yml` passes `GH_REPO_TOKEN: ${{ secrets.DOCKER_PACKAGE_READ }}` on the step, as samna_auth and bookable do.
5. `just deploy` runs `sbump` with `--auto` and moves `.inputs.smig-version.default` in `action.yml`.

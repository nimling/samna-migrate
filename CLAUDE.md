# smig

The `smig` database migration cli every Go service migrates through, Go module `github.com/nimling/samna-migrate`, and the `action.yml` GitHub Action that downloads the pinned release binary onto consumer runners. GitHub `nimling/samna-migrate`. How consumers use it: `../.claude/rules/migrations.md`. Layout and usage: `README.md`.

## Commands

1. `just build`: `bin/smig` with the version ldflags from `.env` `APP_VERSION` or `git describe`.
2. `just install`: `just build`, then `GOPATH/bin/smig`.
3. `just test [TestName]`: `test-go` then `test-docker`; `just test-go` is `go test ./...` without docker; `just test-docker` builds the fake bookable postgres from `database/smig/Dockerfile` and runs `test/e2e` and `test/integration`.
4. `just deploy [patch|minor|major]`: `sbump` moves `APP_VERSION` and `.inputs.smig-version.default` in `action.yml`, tags, pushes and tracks `build-publish-action.yml`.

## Conventions

1. `set dotenv-load` in the justfile: every recipe reads `.env`, so a remote database is reached by calling `bin/smig` or the installed `smig` directly with `--env=<file>`.
2. A `samna_migrate` schema change is a new `internal/upgrade/sql/upgrade_to_<n>.sql`, its `//go:embed` line and `case` in `internal/upgrade/upgrade.go`, and `SchemaVersion` in `pkg/cli/version.go`, in one change.
3. The smig skill ships inside the binary; a command, flag or verdict change edits `.claude/skills/smig` in the same change.

## Index

1. `.claude/rules/deploy.md`, always: where tests go, the schema chain under `internal/upgrade/sql/`, the embedded skill and the release constraints.
2. `.claude/rules/stream.md`, path scoped to `internal/migrate/`, `internal/apply/`, `internal/log/`, `.github/workflows/` and `action.yml`: the smig mcp, its steps, the private module token and how `action.yml` installs the binary.
3. `.claude/skills/smig`: the smig skill, embedded by `skill.go`, exposed at the workspace as `../.claude/skills/smig`; use when running or explaining any smig command or authoring a migration.
4. `.claude/skills/deploy`: use when the user says deploy, release or ship in this repo.
5. `.claude/skills/test`: use when testing a change: `just test`, `just test-go`, `just test-docker`, and what no recipe runs.
6. `.claude/skills/run`: use when building, installing or trying this checkout's smig against the fake bookable postgres.
7. `.claude/rules/cli.md`, always: the cli formula this cli follows and what a change to a command must update.
8. Hidden docs in `.nimpress/`: `mcp.md`, the mcp server and its steps; `release.md`, the docker tests, the release and the private module access.

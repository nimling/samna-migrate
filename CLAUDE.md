# smig

The `smig` database migration cli every Go service migrates through, Go module `github.com/nimling/samna-migrate`, and the `action.yml` GitHub Action that installs it on consumer runners. GitHub `nimling/samna-migrate`. How consumers use it: `../.claude/rules/migrations.md`. Layout and usage: `README.md`.

## Index

1. `.claude/rules/deploy.md`, always: where tests go, the schema chain under `internal/upgrade/sql/`, the embedded skill and the release constraints.
2. `.claude/rules/stream.md`, path scoped to `internal/migrate/`, `internal/apply/`, `internal/log/`, `.github/workflows/` and `action.yml`: the smig mcp, its steps and the private module token.
3. `.claude/skills/smig`: the smig skill, embedded by `skill.go`, exposed at the workspace as `../.claude/skills/smig`; use when running or explaining any smig command or authoring a migration.
4. `.claude/skills/deploy`: use when the user says deploy, release or ship in this repo.
5. `.claude/skills/test`: use when testing a change: `just test`, `just test-go`, `just test-docker`, and what no recipe runs.
6. `.claude/skills/run`: use when building, installing or trying this checkout's smig against the fake bookable postgres.
7. `.claude/rules/cli.md`, always: the cli formula this cli follows and what a change to a command must update.

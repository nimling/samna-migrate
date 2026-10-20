# Testing and releasing smig

The release procedure and the bump commands are the `deploy` skill, the test recipes the `test` skill, and building and running the checkout the `run` skill, under `.claude/skills/`.

## Tests

1. Pure logic: `_test.go` beside the code. Postgres paths: `test/integration/`. CLI behaviour: `test/e2e/`. `test/live/` needs `-tags=live` and `ANTHROPIC_API_KEY`, and no recipe runs it.
2. `just test` runs `test-go` and `test-docker`. `test-docker` needs docker: it builds `database/smig/Dockerfile` into a fake bookable postgres on port 5436 and tears it down after. `just test-go` skips docker.
3. Cover anything that changes exit behaviour, a ledger write, a preflight or reconcile verdict, or a `samna_migrate` schema step.

## Schema chain

A change under `internal/upgrade/sql/` adds `upgrade_to_<n>.sql`, wires it into the `//go:embed` list and the switch in `internal/upgrade/upgrade.go`, and bumps `SchemaVersion` in `pkg/cli/version.go`. Missing any of the three bricks every consumer's boot check. A `SchemaVersion` bump is at least a minor.

## Skill

`.claude/skills/smig` is embedded into the binary by `skill.go` and installed by `smig skill install`. Edit it with the code it describes; it ships in the next release. The workspace reads it through the symlink `../.claude/skills/smig`.

## Releasing

1. `just test` and `just build` pass first.
2. Commit, push, then `just deploy` (patch) or `just deploy minor|major`. It moves `APP_VERSION` and the `smig-version` default in `action.yml` together, tags and pushes.
3. `just install` afterwards so the local `smig` matches the tag.
4. Never hand edit `APP_VERSION` or `action.yml`'s pin, never `git tag`, never `go build` for a release binary: `just build` injects the version ldflags.

# Deploy rules

This repo publishes one artefact: the `smig` CLI, consumed as a Go module via `go get github.com/nimling/samna-migrate` and installed locally via `just install`. The full procedure lives at `.claude/skills/deploy/SKILL.md`. The constraints below apply outside of any single deploy run.

## Never

1. Edit `APP_VERSION` in `.env` by hand. `../sbump/sbump.sh` owns that field. Hand edits drift from the tag.

2. Tag manually with `git tag` or `git push --tags`. `just deploy` writes the tag and pushes it as one operation via `sbump`.

3. Use `--no-verify` or `--no-gpg-sign` on commits going out as part of a release.

4. Skip `just test`, `just vet`, or `just build` before `just deploy`. A red test, a vet finding, or a failing build must block the bump.

5. Run `go build`, `go test`, or `sbump.sh` directly. The `justfile` recipes are the contract: `just build` injects the version ldflags, `just test` runs the unit suite, `just deploy` bumps and tags.

6. Ship a change to `internal/upgrade/sql/` without bumping `SchemaVersion` in `pkg/cli/` and adding the matching `upgrade_to_<n>.sql` step. The boot check on every deployed consumer compares the two.

## Always

1. Add or extend tests for any change with an observable contract: package level `_test.go` files for pure logic, `test/integration/` for paths that need a real postgres, `test/e2e/` for CLI level behaviour.

2. Run `just test-integration` and `just test-e2e` when the change touches `internal/apply`, `internal/preflight`, `internal/upgrade`, `internal/merge`, `internal/verify`, or `internal/schema`. These need docker and the `../bookable_server_test/` sibling checkout.

3. Write a single sentence commit message that describes the user visible change. The release notes derive from `git log` after the tag.

4. Refresh `just install` after a deploy so the local `smig` matches the published tag.

## Version policy

`just deploy` does a patch bump by default. For minor or major, pass the explicit argument to `sbump.sh` instead. The repo does not gate this; the human running the deploy picks the right bump. A `SchemaVersion` bump in `pkg/cli/` is always at least a minor.

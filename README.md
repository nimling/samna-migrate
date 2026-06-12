# samna-migrate (smig)

Database migration runner. Walks a `migrate.yml` step file, applies SQL files in order, records every attempt in `samna_migrate.history`, and gates CI behind an operator-acknowledged local `upgrade` step.

The CLI binary is `smig`.

## Commands

```
smig up         Apply pending migrations after a strict boot check.
smig upgrade    Walk the samna_migrate schema chain and reconcile state. Local only.
smig check      Preflight only. No writes. Reports drift.
smig stat       Print current state and per-step file counts.
smig merge      Rebase live SQL into .upgraded/; --apply moves it in; --revert restores a snapshot.
smig verify     Prove .upgraded/ in a disposable postgres container. Local only.
smig lint       Static checks on every step file. No database needed.
smig lock       Write the applied ledger to samna_migrate.lock.json for lint to guard.
smig rebaseline Accept edited applied files as the new checksum, audited with a reason.
```

## Verify

`smig verify` builds a candidate source tree from `.upgraded/` overlaid on the current tree, bootstraps it into a disposable postgres container started via docker, and records three verdicts: `bootstrap` (the candidate builds a fresh database without errors), `equality` (the fresh database matches the live database object for object across types, tables, constraints, indexes, views, functions, triggers, sequences, grants, and comments), and `reapply` (every base and seed file applies a second time without errors and without changing any object). All three passing writes `.upgraded/verify.json`, the proof `smig merge --apply` requires unless `--force` is given. `--dry-run` reports verdicts without writing the proof. `--keep` leaves the container and candidate tree in place for inspection. `--image` overrides the postgres docker image, which otherwise follows the live server major version.

## Drift guarding

`smig lint` walks every step file and reports filename grammar violations on any step, `session_replication_role` usage, `COMMENT ON FUNCTION` without an argument signature, `CREATE TYPE` without a `pg_type` existence guard, and the non idempotent forms of `CREATE INDEX`, `ADD COLUMN`, and `CREATE FUNCTION` in migration files. Errors exit nonzero; `--strict` promotes warnings. With `samna_migrate.lock.json` present, lint also rejects any locked file that was edited or deleted, which catches checksum tampering at the keystroke instead of at the deploy preflight.

`smig lock` writes the lockfile from the applied rows in `samna_migrate.file`. Commit it. `smig up`, `smig rebaseline`, and `smig merge --apply` refresh it automatically when it exists.

`smig rebaseline <file_path>... --reason <text>` is the supported way to bless an intentional edit to an applied file: it updates `samna_migrate.file` to the disk sha and writes a history row with `action_type = 'rebaseline'` carrying the prior sha, the new sha, and the reason. Confirmation prompts for the database name; `--yes` bypasses.

Preflight treats a drifted base or seed file as a replay: the row flips back to pending and the next `smig up` re-applies it. A drifted applied migration stays fatal. An applied migration missing from disk is fatal; a missing base or seed file warns.

## Workflow

1. Local operator runs `smig upgrade` against the target env. Confirmation prompt asks for the database name.
2. Phase A walks the schema chain to the current `SCHEMA_VERSION`. Phase B writes `yaml_sha256` and `tool_version` into `samna_migrate.state`.
3. CI (or any non-local caller) runs `smig up`. The strict `boot_check` requires equality on `schema_version`, `tool_version`, `yaml_sha256` and refuses to apply if anything is behind.
4. `smig lint` runs in PR CI and pre commit with the committed lockfile, so locked file edits and non idempotent SQL never reach a deploy.

## Building

```
just deps      # go mod tidy
just build     # produces bin/smig
just install   # installs smig to $GOPATH/bin
```

## Testing against a bookable_server clone

The repo expects a sibling directory `../bookable_server_test/` containing a checkout of `bookable_server` at HEAD. The `test-db-up` recipe in `justfile` builds the bookable database image from that checkout and runs it on port `5433` so it does not collide with a normal dev cycle.

## Layout

```
cmd/                  entrypoint
internal/migrate/     cobra commands (up, upgrade, stat, check)
internal/config/      env + dotenv loader
internal/db/          pgxpool wrapper + psql delegate
internal/schema/      samna_migrate.* state helpers
internal/upgrade/     schema chain + embedded SQL
internal/preflight/   disk vs ledger scanner
internal/apply/       per-file apply + history writer
internal/steps/       migrate.yml parser
pkg/cli/              version constants
```

# samna-migrate (smig)

Database migration runner. Walks a `migrate.yml` step file, applies SQL files in order, records every attempt in `samna_migrate.history`, and gates CI behind an operator acknowledged local `upgrade` step.

The CLI binary is `smig`. The help screen animates the smig logo on a terminal and prints it static when piped.

## Commands

```
smig up         Apply pending migrations after a strict boot check.
smig upgrade    Walk the samna_migrate schema chain and reconcile state. Local only.
smig check      Preflight only. No writes. Reports drift.
smig stat       Print current state and per step file counts.
smig merge      Rebase live SQL into .upgraded/; --apply moves it in; --revert restores a snapshot.
smig reconcile  Audit the local tree against the deployed state, then prove .upgraded/ in a container.
smig lint       Static checks on every step file. No database needed.
smig lock       Write the applied ledger to samna_migrate.lock.json for lint to guard.
smig rebase     Mirror local files into samna_migrate as the deployed truth, reversibly.
smig down       Revert applied migrations with an Anthropic agent that synthesizes the down SQL. Local only.
```

## Deployed bodies

Every successful apply records both the sha256 and the full deployed `.sql` body into `samna_migrate.file.applied_sql` and `samna_migrate.history.applied_sql`. The stored body is the raw on disk content, so `smig reconcile` compares the deployed bytes against the working tree line for line.

## Reconcile

`smig reconcile` always runs the audit, and runs the proof when it is needed.

The audit compares every local `.sql` file against the body stored in `samna_migrate` at apply time. It classifies each file as added, dropped, changed, or reordered, groups the results by class as a compact aligned list colored by status, and uses the SQL scanner to name the exact function, table, or statement that differs with its file and line. The difference renders as a git style diff with green additions, red removals, and cyan hunk headers. Normal output lists the per object changes; `-v` adds the diff hunks; `-vv` dumps the full bodies on both sides. The audit reports every difference and only stops at the first one when `--stop-one-error` is given.

The proof builds a candidate source tree from `--db-dir`, overlaying `.upgraded/` when it is present, bootstraps it into a disposable postgres container started via docker, and records three verdicts: `bootstrap` that the candidate builds a fresh database without errors, `equality` that the fresh database matches the live database object for object across types, tables, constraints, indexes, views, functions, triggers, sequences, grants, and comments, and `determinism` that a second independent bootstrap matches the first. All three passing writes `.upgraded/reconcile.json`, the proof `smig merge --apply` requires unless `--force` is given.

The proof runs when `.upgraded/` is present, the merge workflow, or when `--proof` forces it on a bare tree. Without either, reconcile runs the audit alone and needs no docker. `--dry-run` reports verdicts without writing the proof. `--keep` leaves the container and candidate tree in place for inspection. `--image` overrides the postgres docker image, which otherwise follows the live server major version.

## Drift guarding

`smig lint` walks every step file and reports filename grammar violations on any step, `session_replication_role` usage, `COMMENT ON FUNCTION` without an argument signature, `CREATE TYPE` without a `pg_type` existence guard, and the non idempotent forms of `CREATE INDEX`, `ADD COLUMN`, and `CREATE FUNCTION` in migration files. Errors exit nonzero; `--strict` promotes warnings. With `samna_migrate.lock.json` present, lint also rejects any locked file that was edited or deleted, which catches checksum tampering at the keystroke instead of at the deploy preflight.

`smig lock` writes the lockfile from the applied rows in `samna_migrate.file`. Commit it. `smig up`, `smig rebase`, and `smig merge --apply` refresh it automatically when it exists.

`smig rebase` mirrors the local file structure into `samna_migrate` as the deployed truth. With no arguments it mirrors the whole tree; with file paths it mirrors only those files. Each mirror writes the disk sha and body into `samna_migrate.file` and first snapshots the prior body into a history row with `action_type = 'rebase'`, so the change is reversible. `--undo` restores the most recent snapshot for each target file and `--undo-id <history_id>` restores one specific snapshot, both recorded with `action_type = 'rebase_undo'`. The diff between the prior body and the new body shows under `-v`. Confirmation prompts for the database name; `--yes` bypasses.

Preflight treats a drifted base or seed file as a replay: the row flips back to pending and the next `smig up` applies it again. A drifted applied migration stays fatal. An applied migration missing from disk is fatal; a missing base or seed file warns.

## Workflow

1. Local operator runs `smig upgrade` against the target env. Confirmation prompt asks for the database name.
2. Phase A walks the schema chain to the current `SCHEMA_VERSION`. Phase B writes `yaml_sha256` and `tool_version` into `samna_migrate.state`.
3. CI or any non local caller runs `smig up`. The strict `boot_check` requires equality on `schema_version`, `tool_version`, `yaml_sha256` and refuses to apply if anything is behind.
4. `smig lint` runs in PR CI and pre commit with the committed lockfile, so locked file edits and non idempotent SQL never reach a deploy.

## Verbosity

Every command shares one output vocabulary. The default level prints headers, section groups, per file steps, and a success line. `-s` suppresses all output except errors. `-v` adds detail lines and diff hunks. `-vv` dumps every SQL statement and full file bodies. Usage text appears only on `-h` or `--help`, never after a command or on failure.

## Building

```
just deps      # go mod tidy
just build     # produces bin/smig
just install   # installs smig to $GOPATH/bin
```

## Testing against the vendored bookable snapshot

The repo carries a full bookable database tree twice under `database/`: `database/shell/` is applied by its bash `migrate.sh` entrypoint, `database/smig/` by the smig binary itself. `just build-db-shell` runs the shell managed image on port `5435`, `just build-db-smig` the smig managed image on port `5436`, both clear of the bookable dev cycle ports. `just test-integration` and `just test-e2e` build the image they need, run the tagged suite, and tear down.

## Layout

```
cmd/                  entrypoint
internal/migrate/     cobra commands: up, upgrade, stat, check, merge, reconcile, lint, lock, rebase, down
internal/config/      env and dotenv loader
internal/db/          pgxpool wrapper and psql delegate
internal/schema/      samna_migrate.* state helpers
internal/upgrade/     schema chain and embedded SQL
internal/preflight/   disk against ledger scanner
internal/apply/        per file apply and history writer
internal/reconcile/   file and object audit, git style diff, container proof
internal/sqlscan/     SQL statement and object scanner
internal/merge/       rebase live SQL into .upgraded/
internal/lint/        static step file checks
internal/lock/        lockfile reader and writer
internal/steps/       migrate.yml parser
internal/log/         ansi styled output and diff rendering
pkg/cli/              version and schema version constants
```

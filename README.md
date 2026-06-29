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
smig reconcile  Diff the local folder against the live server as a git diff: --files, --objects, --git, --db sections, --json for machine output.
smig lint       Static checks on every step file. No database needed.
smig lock       Write the applied ledger to samna_migrate.lock.json for lint to guard.
smig rebase     Mirror local files into samna_migrate as the deployed truth, reversibly.
smig down       Revert applied migrations with an Anthropic agent that synthesizes the down SQL. Local only.
```

## Agent guide

An agent facing guide to the CLI lives at [.claude/skills/smig/SKILL.md](.claude/skills/smig/SKILL.md). It explains every command, when to reach for each, how to turn the `reconcile --db --json` report into hand applied SQL, and the safety rules that bound writes against a live database.

## Deployed bodies

Every successful apply records both the sha256 and the full deployed `.sql` body into `samna_migrate.file.applied_sql` and `samna_migrate.history.applied_sql`. The stored body is the raw on disk content, so `smig reconcile` compares the deployed bytes against the working tree line for line.

## Reconcile

`smig reconcile` diffs the local database folder, `--db-dir` (default `./database`), against the live server and renders everything that differs in a git diff look. It has two independent axes. Section flags select which approaches run and render, each collecting the maximum it can: `--files`, `--objects`, `--git`, `--db`. With none set, all four run, the joint. `--json` is the output format, orthogonal to the sections; bare `--json` emits the joint as machine data, `--db --json` emits only the database comparison. Every object entry carries the remediation direction, create, drop, or update on live, the current live DDL, the desired SQL the files define, and an apply phase ordering, so the report is enough to write the SQL that makes two servers match. When `--db` is selected and docker is absent, reconcile reports that docker is required.

The file audit compares every local `.sql` file against the body stored in `samna_migrate` at apply time. It classifies each file as added, dropped, changed, or reordered, groups the results by class as a compact aligned list colored by status, and names the function, table, or statement that differs with its file and line. The difference renders as a git style diff with green additions, red removals, and cyan hunk headers. `-v` adds the diff hunks, `-vv` the full bodies. The audit reports every difference and only stops at the first one when `--stop-one-error` is given.

The object analysis tracks every created object globally across all files and compares the working tree against the bodies stored at apply time. Only createable kinds are tracked, function, table, view, type, sequence, trigger, index, domain, policy, and schema; `DROP`, `ALTER`, `INSERT`, and `DO` statements are not objects and never appear. Triggers, indexes, and policies are keyed by their table so distinct ones with the same name stay distinct. For each object it reports whether it moved to another file, was renamed by best effort body match, changed signature, changed content, changed position, was added, or deleted, each as a git style diff carrying the from and to file and line, with reasons deduplicated.

The git section (`--git`), when the folder is a git repository, prints the real `git diff` of each changed, dropped, or reordered file between the commit it was deployed from and the working tree. The deployed commit is captured into `samna_migrate.file.applied_commit` during `smig up`, `smig rebase`, and `smig merge --apply`. It is silently skipped when the folder is not a git repo or a file is untracked.

The database comparison (`--db`) starts a local docker postgres, applies every local file from `--db-dir` into it resiliently, introspects the produced objects, and compares them object for object against the live server across every kind: functions, tables and columns, constraints, indexes, triggers, views, types, sequences, grants, and comments. Each difference renders as a unified DDL diff of the current live definition against the definition the files produce, with a remediation direction and an apply phase. Table columns are compared by name, not by position, so a reordered column is never a false difference; a real column difference is an add, drop, or alter per column, and a dropped column marks the change destructive. Objects owned by an extension via `pg_depend`, such as the `pgcrypto` functions, are recognized and never reported as drop on live. When the build does not complete, every only-in-live verdict is downgraded to review because the missing object may belong to a file that failed to build. The files apply with their step `pre` and `vars` expanded from the environment, so run reconcile with the deploy env; a build failure is recorded and reported without stopping the other sections. `--keep` leaves the container and candidate tree for inspection. `--image` overrides the postgres docker image, which otherwise follows the live server major version.

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

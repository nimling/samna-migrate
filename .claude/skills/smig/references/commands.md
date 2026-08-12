# smig commands

Every command in the binary, what it reads, what it writes, and its flags. Load this when a command needs more than the picker in `SKILL.md` gives.

## Write profile at a glance

1. Reads only: `stat`, `lint`, `reconcile`, `dump`.

2. Writes ledger rows only: `check`, `upgrade`, `rebase`.

3. Writes the live schema or its data: `up`, `run`, `down`, `insert`, `destroy`, `merge --apply`.

4. Writes the source tree: `merge`, `merge --apply`, `merge --revert`.

## stat

Prints `samna_migrate.state`, recent history, and per step file counts. Reach for it first to learn where a database stands. Safe anywhere.

## check

Preflight. Runs `boot_check`, then scans disk against the ledger and reports new, unchanged, drift, and missing counts without applying SQL.

It is not read only. `preflight.Scan` inserts a row for every file with no ledger entry and sets a drifted applied base or seed file back to `pending`. A migration whose disk bytes differ from `samna_migrate.file.sha256` is fatal, and an applied migration missing from disk is fatal.

## lint

Static checks on every step file, no database needed. Reports:

1. error, filename grammar violations on any step.

2. error, a filename whose slug names no area declared in `migrate.yml`.

3. error, `session_replication_role` usage.

4. error, `COMMENT ON FUNCTION` without an argument signature.

5. warn, `CREATE TYPE` without a `pg_type` or `duplicate_object` guard.

6. warn, `CREATE INDEX`, `ADD COLUMN`, or `CREATE FUNCTION` without their idempotent form in migration files.

Errors exit nonzero. `--strict` promotes warnings to errors. Every check runs every time.

A step whose `if` condition is false is skipped entirely, so its files are never scanned. Set the variables that gate the seed steps before trusting a clean run.

## upgrade

Local operator only. Walks the `samna_migrate` schema chain to the tool's `SchemaVersion`, then writes `yaml_sha256` and `tool_version` into `samna_migrate.state`. This is the acknowledgement that lets a later `up` pass `boot_check`. Run it after installing a new `smig` or editing `migrate.yml`. Prompts for the database name.

## up

Applies every pending file in order, recording sha, body, and deployed commit. Order is step order and version, not discovery position. A drifted base or seed file is replayed. A drifted applied migration is fatal. An applied migration missing from disk is fatal.

`up [target]` stops after the named file. `-i` or `--interactive` presents the grouped pending list and lets the operator pick the stop point.

Target grammar, shared with `run`: a 1 based number from the list, a `slug:version` pair such as `claimius:2.4`, a file name, a file path, or a step slug.

## run

Runs exactly one step or SQL file, recording the apply in the ledger like `up` does. Same target grammar, where a step slug runs every pending file of that step. `-i` presents the grouped list.

A path resolving to a SQL file outside the tree is refused unless `--force`, which executes it as an external file recorded with an `external` marker. Use `run` to reapply one seed or push one file ahead of a full `up`. Use `--force` external runs only for one off corrective SQL the user has reviewed.

## reconcile

Compares the tree against a live server and renders drift as a git style diff. Read only against the live server. See `reconcile.md`.

## merge

Rebases live SQL into a staging tree and optionally promotes it.

1. `merge` writes the live SQL of every base and seed file into `.upgraded/`, then routes migration files into base targets when identifiers match. Source tree and database untouched.

2. `merge --apply` snapshots the source tree to `.migrate-<ts>-<sha>/`, moves `.upgraded/` into the tree, and reconciles `samna_migrate.file` rows. Requires the proof written by `reconcile` unless `--force`. `--tag` writes a git annotated tag.

3. `merge --revert [n]` restores a prior `.migrate-<n>/` snapshot, newest by default. Refuses unless the last merge action was an apply, unless `--force`.

## rebase

Mirrors on disk content into `samna_migrate` as deployed truth, reversibly. No arguments mirrors the whole tree, file paths mirror only those. Each mirror snapshots the prior body into a history row with `action_type = 'rebase'`, so `--undo` restores the most recent snapshot and `--undo-id <history_id>` restores a specific one. `--reason` records why. Prompts for the database name.

A path with no ledger row is registered rather than skipped, which is what makes a scoped `rebase` the correct pairing for a file rename.

`--prune` makes the ledger describe the current file structure. Every applied entry whose file is absent from the tree is folded, with a `fold` history row, and every file on disk is recorded as applied at its own content. Bare `--prune` covers every step and is the same as `--prune=all`. A value scopes it to one step by type, slug or name, so `--prune=migration` folds the entries a history squash leaves, which is where `up` aborts with `applied but absent from the source tree`, and `--prune=debug_user` narrows to that seed step.

Use it after folding migrations into a base file, or after renaming files, where the same SQL is deployed but the tree expresses it under different paths. Confirming the prompt is the statement that the local tree is the deployed truth, so no SQL is executed and nothing is re seeded.

## down

Local operator only, AI powered, refuses in CI. Walks applied migration rows in descending order and reverts each. Per step it reuses a cached `down_proposal` when present, otherwise calls the Anthropic Messages API to synthesise the down SQL from the forward SQL and current database state, validates it inside a rollback transaction, executes it, and writes a `down` history row pointing at the original apply.

Requires `--anthropic-key` or `ANTHROPIC_API_KEY`. `--to <file_path|history_id>` reverts until a target, `--steps N` reverts the N most recent, `--dry-run` prints the proposed SQL without executing. Always dry run first and show the user the SQL.

## dump

Reads a live database and writes json to disk, one `<schema>.<table>.json` per table, limited to base tables in the schemas declared by `migrate.yml`. `--all` selects every such table, `--table=<schema.table>` is repeatable and comma joined, `--out=<dir>` sets the destination.

With no selection flag and a terminal, an arrow key list lets the operator pick tables with space, `a` toggles all, enter confirms, then it asks for the output path. Rows encode through `jsonb_agg(to_jsonb(...))` so postgres owns type fidelity for uuid, numeric, jsonb, and timestamptz.

## insert

Loads json produced by `dump` back into its tables. Point it at a folder, which loads every `.json` inside, or at individual files from positional arguments and repeated `--path` flags. With none, the current directory is used.

The target table comes from each file name. Rows load through `jsonb_populate_recordset` so columns are typed from the table, generated columns excluded, one transaction per file. `--no-triggers` disables user triggers for the load and re enables them after.

## destroy

Destructive teardown, needs docker. Builds every `migrate.yml` file into a throwaway docker postgres, inventories exactly the objects those files create, and drops that set from the live server in one transaction: declared schemas other than `public` with schema level cascade drops, objects in `public` individually with `DROP ... IF EXISTS CASCADE`.

Objects owned by an extension are excluded so the individual drops do not fail. The `samna_migrate` ledger is always dropped so a following `up` re applies from scratch. `--extensions` also drops the extensions the tree creates, never `plpgsql`.

Because the object set comes from a real build, `public` objects the tree does not create are untouched. `--image` overrides the candidate image when the tree needs extensions the plain image lacks, for example `--image=pgvector/pgvector:pg17`. Without it the candidate build fails and the plan misses every downstream object.

The plan is printed and the database name is required to confirm. `--dry-run` prints the plan and drops nothing, `--yes` bypasses the prompt.

## completion

Prints the shell completion script, or installs it with `--auto`. `--auto` detects the shell from `$SHELL` when none is given, writes a smig owned file under `~/.config/smig/completions`, and points the shell rc at it inside a managed block. fish loads from its own directory and needs no rc change. `--skill` installs the claude skill in the same step.

## skill

`skill get` prints the skill document to stdout. `skill put` installs the whole skill tree under `~/.claude/skills/smig`, or into `.claude` of the current directory with `--project`. The tree is embedded in the binary, so an installed skill always matches the installed tool.

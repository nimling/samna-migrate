---
name: smig
description: Drives the smig database migration CLI. Use when running migrations, checking migration state, diagnosing schema drift, applying a single step or file, seeding, dumping or inserting table data, destroying and rebuilding a database, authoring a migration filename, or invoking any smig command.
---

# smig

`smig` walks a `migrate.yml` step file, applies SQL files in order, records every attempt in the `samna_migrate` schema, and gates CI behind an operator acknowledged local upgrade.

Read this before running any `smig` command on behalf of a user. When the intent is unclear, ask which database and which environment. Never guess.

## Two callers, different rights

1. The local operator runs `upgrade`, `down`, `rebase`, `merge`, `destroy`. These touch ledger state or the tree itself. `down` refuses to run in CI.

2. CI runs `up`. Before applying, `boot_check` demands the database match the working tree on `schema_version`, `tool_version`, and the `yaml_sha256` of `migrate.yml`. If anything is behind, `up` refuses and asks for a local `upgrade`. Never bypass that by writing `samna_migrate.state` directly.

Every successful apply stores the raw `.sql` body and its sha256 in `samna_migrate.file` and `samna_migrate.history`, so the deployed bytes are always available to diff against the tree.

## Pick a command by intent

1. Learn where a database stands: `stat`. Read only.

2. Ask whether `up` would apply cleanly: `check`. It writes discovery rows, see the note below.

3. Validate filenames and SQL shape with no database: `lint`.

4. Acknowledge a new tool version or an edited `migrate.yml`: `upgrade`.

5. Deploy: `up`. One step or one file only: `run`.

6. Understand divergence between the tree and a live server, or author corrective SQL: `reconcile`.

7. Align the ledger to disk without executing SQL: `rebase`. Clear orphaned applied migrations after a squash: `rebase --prune`.

8. Pull live SQL back into the tree: `merge`.

9. Revert applied migrations: `down`. Local only, AI powered, always dry run first.

10. Move table data: `dump` reads, `insert` writes.

11. Tear the tree's objects out of a server: `destroy`. Dry run first, always.

Full per command detail, every flag, and the target grammar are in `references/commands.md`.

## check is not read only

`check` runs `preflight.Scan`, which inserts a ledger row for every file it has not seen and flips a drifted applied base or seed file to `pending`. Against a shared server that changes what the next `up` will apply. Run it against a local or throwaway database, or accept the ledger write deliberately.

## Authoring

Step types, the `V<version>__<slug>_<name>.sql` filename grammar, and how an include entry resolves from a folder, a git repo, or a url are in `references/authoring.md`.

The identity of a file in the ledger is its path relative to the database directory. Renaming a file makes it a new file to every server, so pair any rename with a scoped `rebase` before the next `up`.

## Reconcile

The four sections, the JSON field contract, and how to turn that JSON into corrective SQL are in `references/reconcile.md`.

## Connection

`smig` reads `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`. Load a dotenv with `--env=<file>`.

Every long value flag takes its value with an equals sign. `--env=.env.prd`, never `--env .env.prd`. The spaced form is rejected at `internal/migrate/root.go:78`.

Two ways a passed env is silently ignored:

1. A consumer justfile with `set dotenv-load` injects that repo's `.env` first, and `smig` fills only the libpq keys that are unset or empty at `internal/config/config.go:76`. So `--env=.env.prd` through a `just migrate` recipe is a no op and the run targets local. Call the binary directly with `--schema` and `--db-dir` instead.

2. A libpq variable already exported in the shell wins for the same reason.

Persistent flags: `--schema`, `--db-dir`, `--env`, `-y` or `--yes`, `--force`, `-s` or `--silent`, `-v`, `-vv`, plus `--anthropic-key` and `--model` for `down`.

## Hard rules

1. Never bypass `boot_check`. When `up` refuses, run `upgrade` locally.

2. Never run `down`, `merge --apply`, or `merge --revert` without showing the user what will change first.

3. Never apply a reconcile remediation marked `destructive` or `review` without explicit confirmation.

4. Never run `destroy` without `--dry-run` first and explicit confirmation, and never when the dry run reports build errors.

5. Run write commands with the same env as the real deploy. A wrong `PGDATABASE` writes to the wrong server.

6. Prefer `stat` before any write, and remember `check` itself writes.

7. `insert` writes rows. Confirm `PGDATABASE` first, the same as any write path.

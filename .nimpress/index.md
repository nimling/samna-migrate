---
layout: doc
title: Samna Migrate
description: The migration runner for every Go service in the Samna stack, applying versioned SQL through an audited ledger.
tags: samna migrate, smig, migrations, postgres, samna_migrate
lastUpdated: true
---

# Samna Migrate

Samna Migrate is the migration runner for every Go service in the Samna stack. Its CLI binary `smig` installs to `GOPATH/bin/smig`. Samna Migrate walks a `migrate.yml` step file, applies SQL files in version order, and records every apply in the `samna_migrate` schema as the deployed ledger. CI gates a deploy behind an operator acknowledged local upgrade.

**Repository**: [nimling/samna-migrate](https://github.com/nimling/samna-migrate)

## Command surface

| Command | Writes live | Use |
|---|---|---|
| `stat` | no | Print `samna_migrate.state` and recent history. |
| `check` | no | Preflight. Report new, drift, and missing counts without applying. |
| `lint` | no | Static checks on every step file. |
| `upgrade` | state only | Acknowledge schema and yaml locally so a later `up` passes the boot check. |
| `up` | yes | Apply pending migrations. The deploy path. |
| `reconcile` | no | Diff the local tree against a live server in depth. |
| `merge` | with `--apply` | Fold live SQL into a staging tree and optionally promote it. |
| `rebase` | ledger only | Mirror on disk content into the ledger as the deployed truth. |
| `lock` | lockfile | Write the applied file ledger to `samna_migrate.lock.json`. |
| `down` | yes | AI assisted revert of applied migrations. Refuses in CI. |
| `dump` | no | Dump table data to json, one `<schema>.<table>.json` per table. |
| `insert` | yes | Insert rows from `<schema>.<table>.json` files back into their tables. |
| `destroy` | yes | Drop every object the tree creates and reset the ledger. Needs docker. |

## Targeting an environment

`smig` reads the target database from the standard libpq variables `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`. Load a dotenv file with `--env=<file>`. Every long value flag takes its value with an equals sign: write `--env=.env.prd`, never `--env .env.prd`.

## Reconcile is the drift check

`reconcile --db` builds the local tree into a throwaway Postgres and diffs the produced objects against the live server across functions, tables, columns, constraints, indexes, triggers, views, types, sequences, grants, and comments. Read the header line `deployed N of M files, K build errors` first: a nonzero build error count downgrades every only-in-live verdict to review, because a file that failed to build never produced its objects. The three buckets that follow are `produced, not in live` when the tree is ahead, `only in live` when live carries objects the tree does not build, and `definition differs` when the materialised DDL drifted.

## Data and teardown

`dump` writes the rows of each selected table to `<schema>.<table>.json` in the output directory, limited to the base tables in the schemas declared by `migrate.yml`. `--all` dumps every such table, `--table=<schema.table>` a subset, `--out=<dir>` sets the destination. With no selection flag and a terminal it opens an arrow key list. Postgres encodes each file with `jsonb_agg(to_jsonb(...))`, so uuid, numeric, jsonb, and timestamptz round trip exactly.

`insert` loads those files back. Point it at a folder or individual files; the target table is read from each file name and rows load through `jsonb_populate_recordset` so every column is typed from the table itself. `--no-triggers` disables user triggers on the table for the load.

`destroy` tears a database down to nothing the tree defines. It builds the tree into a throwaway Postgres, inventories exactly the objects those files produce, and drops that set from the live server: declared schemas other than `public` with `DROP SCHEMA CASCADE`, objects in `public` one by one with `DROP ... IF EXISTS CASCADE`. It then resets `samna_migrate.file` so a following `up` re-applies from scratch. The plan is printed and the database name is required to confirm; `--dry-run` prints the plan and drops nothing.

```sh
smig dump --all --out=./snapshot --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
smig destroy --dry-run --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
smig insert ./snapshot --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
```

## Reconciling a history squash

When a migration history is squashed, the migration files are folded into the baseline and deleted from the tree, but the live ledger still carries them as applied. `up` then aborts with `applied but absent from the source tree`.

`rebase --prune` clears exactly that state. It folds every applied migration row whose file is absent from the tree, setting `state = 'folded'` and writing a `fold` history row per entry, and leaves pending files untouched so a following `up` applies the genuinely new migrations.

```sh
smig reconcile --db --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
smig rebase --prune --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
smig up --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
```

Run `reconcile --db` first to confirm the tree still produces the folded migrations' objects: the only-in-live bucket must hold nothing beyond what the squash intentionally dropped. The fold is recorded in history and reversed by restoring the source file. A plain whole-tree `rebase` would instead stamp pending files as applied without running their SQL, so `--prune` is the correct tool for orphaned entries.

---
name: smig
description: Drive the smig database migration CLI as an AI agent. Explains every command, when to reach for it, the apply pipeline, the reconcile report, and the safety rules that bound writes against a live database.
---

# smig

`smig` is the database migration runner for the Samna stack. It walks a `migrate.yml` step file, applies SQL files in order, records every attempt in the `samna_migrate` schema, and gates CI behind an operator acknowledged local upgrade. This skill tells an agent which command to run for a given intent and which commands write to a live database.

Read this before running any `smig` command on behalf of a user. When the intent is unclear, ask which database and which environment, never guess.

## The mental model

There are two callers and they have different rights.

1. The local operator runs `smig upgrade` and `smig down`. These touch the `samna_migrate` schema chain and revert state. They refuse to run in CI.

2. CI or any automated caller runs `smig up`. Before applying, a strict `boot_check` demands the database is exactly aligned with the working tree on `schema_version`, `tool_version`, and the `yaml_sha256` of `migrate.yml`. If anything is behind, `up` refuses and tells the operator to run `smig upgrade` locally. The agent never bypasses this by editing schema state directly.

Every successful apply stores the raw `.sql` body and its sha256 into `samna_migrate.file` and `samna_migrate.history`, so the deployed bytes are always available to diff against the working tree.

## Connection and global flags

`smig` reads the target database from the standard libpq environment: `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`. Load a dotenv with `--env=<file>` when the deploy env lives in a file. Run `reconcile --db`, `up`, and `merge` with the same env the real deploy uses, because files apply with their step `pre` and `vars` expanded from the environment.

Every long value flag takes its value with an equals sign: `--env=.env.prd`, never `--env .env.prd`. The spaced form is rejected before dispatch at `internal/migrate/root.go:78`.

Two ways the env you pass is silently ignored:

1. A consumer repo justfile with `set dotenv-load` injects that repo's `.env` into the recipe environment first. `smig` fills only the libpq keys that are unset or empty at `internal/config/config.go:76`, so `--env=.env.prd` passed through a `just migrate` recipe is a no op and the run targets local. To hit a non default environment, call the `smig` binary directly with `--schema` and `--db-dir`, not the justfile recipe:

```
smig reconcile --db --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
```

2. A libpq variable already exported in your shell wins over the dotenv for the same reason. Clear `PGHOST` and friends, or run in a clean shell, when the dotenv must take effect.

Persistent flags available on every command:

1. `--schema` path to `migrate.yml`, default `./database/migrate.yml`, env `MIGRATE_SCHEMA`.

2. `--db-dir` path to the database directory, default `./database`, env `DB_DIR`.

3. `--env` optional dotenv file to load first.

4. `-y` / `--yes` bypass interactive confirmation prompts.

5. `--force` bypass safety checks where a command supports it.

6. `-s` / `--silent` errors only. `-v` verbose adds detail and diff hunks. `-vv` dumps every SQL statement and full bodies.

7. `--anthropic-key` or env `ANTHROPIC_API_KEY`, and `--model`, both only for the AI powered `down` command.

## Commands by intent

### smig stat

Read only. Prints `samna_migrate.state` and recent history with per step file counts. Reach for it first to learn where a database stands before deciding any action. Safe to run anywhere.

### smig check

Read only preflight. Runs `boot_check` then scans disk against the ledger and reports new, unchanged, drift, and missing counts. No writes. Use it to answer whether `up` would apply cleanly without applying. Drift or missing files surface here as warnings.

### smig lint

Static checks on every step file, no database needed. Reports filename grammar violations, `session_replication_role` usage, `COMMENT ON FUNCTION` without an argument signature, `CREATE TYPE` without a `pg_type` guard, and the non idempotent forms of `CREATE INDEX`, `ADD COLUMN`, and `CREATE FUNCTION` in migration files. Errors exit nonzero. `--strict` promotes warnings to errors. With `samna_migrate.lock.json` present it also rejects any locked file that was edited or deleted. Run it before proposing any SQL change and in PR CI.

Each step in `migrate.yml` declares a `type`, required and one of `base` for baseline DDL, `migration` for schema migrations, or `seed` for non DDL seeded data. A `base` or `seed` step declares a `slug` naming the area it deploys to. A `migration` step declares no slug, because its files each target an area owned by another step. `Load` rejects a missing or invalid type, a slug on a migration step, and a missing slug on a base or seed step.

The filename grammar is `V<version>__<slug>_<name>.sql`: a `V` prefix, a dot separated integer version whose leading component is at least 1, the `__` separator, a lowercase alphanumeric slug, an underscore, and a `<name>` of lowercase alphanumerics and underscores. The slug and the name are both required and the version never starts at 0. The `<slug>` must be one of the slugs declared by the steps in `migrate.yml`; `lint` flags any file whose slug names no declared area. So with steps declaring the slugs `claimius` and `base`, `V1.0__claimius_roles.sql` is valid, while `V1.0__roles.sql`, `V0.0__claimius_roles.sql`, and `V1.0__widget_roles.sql` are all rejected. `ParseFilename` and `Config.Slugs` in `internal/steps/steps.go`, and `FILENAME_GRAMMAR` in `database/shell/scripts/migrate.sh`, carry the grammar.

An include entry resolves from a local folder, a git repo, or a url. The local form is `path` with an optional `fallback`. The git form is `git` for the repo, `branch` for the branch to track, `ref` for a tag or commit to pin, `token` for https auth, and `path` for the subfolder inside that repo; smig shallow clones the ref in process with go-git and reads only that subfolder, so no `git` binary is required. `ref` wins when set, otherwise `branch` is used, and `branch` itself defaults to `main`, so an entry with only `git` and `path` tracks the latest `main`. ssh urls authenticate with a default `~/.ssh` key file and fall back to the ssh agent; for https a private repo uses `token`, or `GITHUB_TOKEN` from the environment when `token` is unset. The url form is `url` to an archive with `path` as the subfolder inside it. Every remote field is environment expanded, so `ref: $MIDDLEWARE_VERSION` reads from the env loaded for the run. A local include that is missing is skipped; a git or url include that fails to resolve is a hard error. Resolution is in `internal/steps/steps.go`. Example pulling a prophet claimius set straight from the middleware:

```yaml
include:
  - git: git@github.com:nimling/samna-auth-middleware.git
    ref: v1.1.0-alpha0007
    path: prophet/database
```

### smig upgrade

Local operator only. Walks the `samna_migrate` schema chain to the tool `SchemaVersion`, then writes `yaml_sha256` and `tool_version` into `samna_migrate.state`. This is the acknowledgement step that lets a later `up` pass `boot_check`. Run it after pulling a new `smig` version or editing `migrate.yml`. Prompts for the database name.

### smig up

Apply pending migrations. Runs `boot_check`, then preflight, then applies every pending file in order, recording sha, body, and deployed commit. This is the deploy path. A drifted base or seed file is treated as a replay and reapplied; a drifted applied migration is fatal; an applied migration missing from disk is fatal. Refreshes the lockfile when one exists. Run with the deploy env.

### smig reconcile

Compare the local database folder against the live server in depth and render the drift as a git style diff. This is the command an agent uses to understand divergence and to build hand applied SQL. Four sections, each selectable, all four run when none is named:

1. `--files` each local `.sql` against the body stored at apply time, classified added, dropped, changed, or reordered.

2. `--objects` every created object tracked globally for moves, renames, signature, content, and position changes.

3. `--git` the real `git diff` of each changed, dropped, or reordered file since the commit it was deployed from, when the folder is a git repo.

4. `--db` builds every local file into a fresh docker postgres and diffs the produced objects against the live server across functions, tables and columns, constraints, indexes, triggers, views, types, sequences, grants, and comments. Needs docker.

`--json` is the output format, orthogonal to the sections. Bare `--json` emits the joint; `--db --json` emits only the database comparison. `--keep` leaves the container and candidate tree for inspection. `--image` overrides the postgres image, which otherwise follows the live server major version. `--stop-one-error` stops the file audit at the first difference.

#### Using the reconcile JSON to write SQL

Each object in the JSON carries the fields needed to author corrective SQL:

1. `remediation` is the direction: `create`, `drop`, `update`, `review`, or `none`.

2. `phase` is the apply order: extension, schema, type, table, sequence, function, view, index, constraint, trigger, policy, grant, comment. Emit statements in ascending phase.

3. `destructive` flags a drop or a dropped column. Surface these to the user before applying.

4. `desired_sql` is what the target should hold, `current_live_ddl` is what it holds now. Tables also carry `columns[]` with per column `add`, `alter`, or `drop` and the `live` and `built` definitions.

Fidelity of `desired_sql` and `current_live_ddl` varies by kind, because they come from postgres introspection:

1. Function, index, trigger come out as complete runnable statements. Use them directly.

2. Constraint is the body only. Wrap it in `ALTER TABLE ... ADD CONSTRAINT`.

3. Table is a column list, not a `CREATE TABLE`. Build the `ALTER TABLE` from `columns[]`.

4. View is the query only. Wrap it in `CREATE OR REPLACE VIEW`.

5. Sequence, enum, grant, comment are summary strings. Reconstruct the statement from the fields. The identity and the remediation direction carry everything needed:

5.1. Grant. `signature` is `function <schema>.<fn>(<args>) <grantee>` and `desired_sql` is the privilege, for example `EXECUTE`. `create`: `GRANT <privilege> ON FUNCTION <schema>.<fn>(<args>) TO <grantee>`. `drop` or `review`: `REVOKE <privilege> ON FUNCTION <schema>.<fn>(<args>) FROM <grantee>`. The grantee is the trailing token of the identity, `public` maps to `PUBLIC`.

5.2. Comment. `signature` is `function <schema>.<fn>(<args>)` and `desired_sql` is the comment text. `create`: `COMMENT ON FUNCTION <schema>.<fn>(<args>) IS '<text>'`. `drop` or `review`: `COMMENT ON FUNCTION <schema>.<fn>(<args>) IS NULL`.

5.3. Sequence and enum summaries carry data_type, start, increment, or the label list. They omit min, max, cache, ownership, storage, and collation. When a diff lands on one of those attributes, introspect that single object for the missing detail before authoring the `ALTER`.

When the docker build is incomplete, only in live verdicts are downgraded from `drop` to `review`. Never drop on a partial build. Resolve `build_errors` and re-run first. Extension owned objects via `pg_depend` are recognised and never reported as drop on live.

#### Worked example: reconcile a tree against prd

```
smig reconcile --db --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
```

Read the header line `deployed N of M files into the container, K build errors` first. When K is nonzero the only in live list is suspect, because a file that failed to build never produced its objects, so they surface as `only in live` without being live only drift. Then read the three buckets: `produced, not in live` means the tree is ahead of live, `only in live` means live has objects the tree does not build or the build failed, `definition differs` means the materialised DDL drifted. Add `--json` to lift the fields above and synthesise the corrective SQL.

### smig merge

Rebase live SQL into a staging tree and optionally promote it. Three modes:

1. `merge` writes the live SQL of every base and seed file into `.upgraded/`, then routes migration files into base targets when identifiers match. Source tree and database untouched.

2. `merge --apply` snapshots the source tree to `.migrate-<ts>-<sha>/`, moves `.upgraded/` into the source tree, and reconciles `samna_migrate.file` rows. Requires the proof written by `smig reconcile` unless `--force`. `--tag` writes a git annotated tag during apply.

3. `merge --revert [n]` restores a prior `.migrate-<n>/` snapshot, defaulting to the most recent. Refuses unless the last merge action was an apply, unless `--force`.

### smig rebase

Mirror the on disk file content into `samna_migrate` as the deployed truth, reversibly. With no arguments it mirrors the whole tree; with file paths it mirrors only those. Each mirror snapshots the prior body into a history row with `action_type = 'rebase'` first, so `--undo` restores the most recent snapshot and `--undo-id <history_id>` restores one specific snapshot. Use it to align the ledger to disk without reapplying SQL, for example after fixing a body that already matches live. `--reason` records why. Prompts for the database name.

`--prune` is the other direction of aligning the ledger to disk. It folds every applied migration row whose file is absent from the source tree, setting `state = 'folded'` and writing a `fold` history row per entry, then refreshes the lockfile. This is the state a history squash leaves: migration files were folded into the baseline and deleted from the tree, but the live ledger still carries them as applied, so `up` aborts with `applied but absent from the source tree`. `rebase --prune` clears exactly those rows and leaves pending files untouched, so a following `up` applies the genuinely new migrations. Run `reconcile --db` first to confirm the tree still produces the folded migrations' objects against live; the only-in-live bucket must hold nothing beyond what the squash intentionally dropped. Mirror, by contrast, would stamp pending files as applied without running their SQL, so prune is the correct tool for orphaned entries.

### smig lock

Write the applied file ledger to `samna_migrate.lock.json` in the database directory. Commit the file. `smig lint` then rejects any edit to a locked file, catching checksum drift at the keystroke. `up`, `rebase`, and `merge --apply` refresh the lockfile automatically when it exists.

### smig down

Local operator only, AI powered, refuses in CI. Walks applied migration rows in descending order and reverts each. For each step it reuses a cached `down_proposal` if present, otherwise calls the Anthropic Messages API to synthesise the down SQL from the forward SQL and the current database state, validates it inside a rollback transaction, executes it, and writes a `down` history row pointing back at the original apply. Requires `--anthropic-key` or `ANTHROPIC_API_KEY`. `--to <file_path|history_id>` reverts until a target, `--steps N` reverts the N most recent, `--dry-run` prints the proposed down SQL without executing. Always dry run first and show the user the proposed SQL before executing.

## Standard workflow

1. `smig upgrade` against the target env, locally, to acknowledge the schema and yaml.

2. `smig lint` in pre commit and PR CI with the committed lockfile.

3. `smig up` from CI. `boot_check` enforces equality on schema_version, tool_version, and yaml_sha256 and refuses if anything is behind.

4. `smig reconcile` whenever live and the tree may have diverged, or to produce SQL that makes two servers match.

## Hard rules for the agent

1. Never bypass `boot_check`. If `up` refuses, the fix is `smig upgrade` locally, not a direct write to `samna_migrate.state`.

2. Never run `down`, `merge --apply`, or `merge --revert` without showing the user what will change first. `down` and `merge --revert` are reversal paths; `merge --apply` rewrites the source tree.

3. Never apply reconcile remediation marked `destructive` or `review` without explicit user confirmation.

4. Run write commands with the same env as the real deploy. A wrong `PGDATABASE` writes to the wrong server.

5. Do not edit `samna_migrate.lock.json` by hand. `smig lock` and the apply commands own it.

6. Prefer `stat` and `check` to understand state before any write.

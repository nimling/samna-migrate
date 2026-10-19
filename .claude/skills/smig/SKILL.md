---
name: smig
description: Drives the smig database migration CLI. Use when running migrations, checking migration state, diagnosing schema drift, applying a single step or file, seeding, dumping or inserting table data, destroying and rebuilding a database, authoring a migration filename, or invoking any smig command. Not for building, testing or releasing smig itself, which are the run, test and deploy skills of the samna-migrate repo, and not for version bumps, which is the sbump skill.
argument-hint: [stat|check|lint|upgrade|up|run|reconcile|rebase|merge|down|dump|insert|destroy|test] [args]
allowed-tools: Bash(smig *)
---

Running and explaining every `smig` command and authoring the files it applies. Building and releasing smig are the `run`, `test` and `deploy` skills of the samna-migrate repo.

`smig` walks a `migrate.yml` step file, applies SQL files in order, records every attempt in the `samna_migrate` schema, and gates CI behind an operator acknowledged local upgrade. Read this before running any `smig` command for a user; when the database or the environment is unclear, ask, never guess.

## Two callers

1. The local operator runs `upgrade`, `down`, `rebase`, `merge`, `destroy`. They touch ledger state or the tree. `down` refuses to run in CI.
2. CI runs `up`. `boot_check` first demands the database match the tree on `schema_version`, `tool_version` and the `yaml_sha256` of `migrate.yml`; anything behind and `up` refuses and asks for a local `upgrade`. Never bypass it by writing `samna_migrate.state`.
3. Every successful apply stores the raw `.sql` body and its sha256 in `samna_migrate.file` and `samna_migrate.history`, so the deployed bytes can always be diffed against the tree.

## Pick a command by intent

1. Where a database stands: `stat`. Read only.
2. Would `up` apply cleanly: `check`. It writes, see Check writes below.
3. Filenames and SQL shape with no database: `lint`.
4. Acknowledge a new tool version or an edited `migrate.yml`: `upgrade`.
5. Deploy: `up`. One step or one file only: `run`.
6. Divergence between the tree and a live server, or corrective SQL: `reconcile`.
7. Align the ledger to disk without executing SQL: `rebase`. Describe the current file structure after a fold or a rename: `rebase --prune`, scoped with `--prune=<step>`.
8. Pull live SQL back into the tree: `merge`.
9. Revert applied migrations: `down`. Local only, AI powered, dry run first.
10. Move table data: `dump` reads, `insert` writes.
11. Tear the tree's objects out of a server: `destroy`. Dry run first, always.
12. Prove the tree with pgTAP against a throwaway database, fresh and upgraded from a ref: `test`; scaffold a file with `test new`. Needs docker, touches no server.
13. Every flag and the target grammar per command: `references/commands.md`.

## Check writes

1. `check` runs `preflight.Scan`, which inserts a ledger row for every unseen file and flips a drifted applied base or seed file to `pending`. Against a shared server that changes what the next `up` applies.
2. Run it against a local or throwaway database, or accept the ledger write deliberately.

## Authoring

1. Step types, the `V<version>__<slug>_<name>.sql` filename grammar, and how an include resolves from a folder, a git repo or a url: `references/authoring.md`.
2. A file's ledger identity is its path relative to the database directory. A rename is a new file to every server; pair it with `rebase --prune` before the next `up`.

## Reconcile

1. The four sections, the JSON field contract, and turning that JSON into corrective SQL: `references/reconcile.md`.

## Connection

1. `smig` reads `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`. Load a dotenv with `--env=<file>`.
2. Every long value flag takes its value with an equals sign: `--env=.env.prd`, never `--env .env.prd`. The spaced form is rejected at `internal/migrate/root.go:78`.
3. A consumer justfile with `set dotenv-load` injects that repo's `.env` first, and `smig` fills only the libpq keys that are unset or empty, `internal/config/config.go:76`. So `--env=.env.prd` through a `just migrate` recipe is a no op that targets local. Call the binary directly with `--schema` and `--db-dir`.
4. A libpq variable already exported in the shell wins for the same reason.
5. Persistent flags: `--schema`, `--db-dir`, `--env`, `-y` or `--yes`, `--force`, `-s` or `--silent`, `-v`, `-vv`, and `--anthropic-key` and `--model` for `down`.

## Hard rules

1. Never bypass `boot_check`. When `up` refuses, run `upgrade` locally.
2. Never run `down`, `merge --apply` or `merge --revert` without showing the user what will change first.
3. Never apply a reconcile remediation marked `destructive` or `review` without explicit confirmation.
4. Never run `destroy` without `--dry-run` first and explicit confirmation, and never when the dry run reports build errors.
5. Run write commands with the same env as the real deploy. A wrong `PGDATABASE` writes to the wrong server.
6. Run `stat` before any write, and remember `check` writes.
7. `insert` writes rows; confirm `PGDATABASE` first.

## mcp

1. `smig mcp` serves every command but `skill`, `completion`, `version` and `help` as a tool over stdio, named by its path, positional arguments as `args`, flags as `flags`.
2. A tool call runs `smig` in the directory claude was started in, with the same environment and `--env=<file>`.
3. Each file `up`, `run` or `rebase` applies is a step; a host that renders MCP Apps shows them live with the result on `ui://smig/run`.

---
name: smig
description: Drives the smig database migration CLI. Use when running migrations, checking migration state, diagnosing schema drift, applying a single step or file, seeding, dumping or inserting table data, destroying and rebuilding a database, authoring a migration filename, or invoking any smig command. Not for building, testing or releasing smig itself, which are the run, test and deploy skills of the samna-migrate repo, and not for version bumps, which is the sbump skill.
argument-hint: [stat|check|lint|upgrade|up|run|reconcile|rebase|merge|down|dump|insert|destroy|test] [args]
allowed-tools: Bash(smig *)
---

Running and explaining every `smig` command and authoring the files it applies. Building and releasing smig are the `run`, `test` and `deploy` skills of the samna-migrate repo.

`smig` walks a `migrate.yml` step file, applies SQL files in order, records every attempt in the `samna_migrate` schema, and gates CI behind an operator acknowledged local upgrade. Read this before running any `smig` command for a user; when the database or the environment is unclear, ask, never guess.

## Two callers

1. The local operator runs `upgrade`, `down`, `rebase`, `merge`, `destroy`. They touch ledger state or the tree; `upgrade`, `rebase` and `destroy` ask for the database name before they write.
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

1. `smig` reads `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`, plus `MIGRATE_SCHEMA`, `DB_DIR`, `GITHUB_TOKEN`, `SMIG_SSH_KEY`, `SMIG_SSH_KEY_PASSWORD` and `ANTHROPIC_API_KEY`. The config is `cli.Settings` from `nimbody/cli`, wired in `internal/migrate/config.go`.
2. Each value resolves the flag, the process environment, `--env=<file>` dotenv layers, a local `.smig/config.yaml` found walking up from the working directory, then the named config in `~/.smig/config.yaml` picked by `--config=<name>`, `SMIG_CONFIG`, the local `use:`, then `default:`. An `--env` file loads every key in it, not only the ones above, so `migrate.yml` expansions such as `$SAUTH_DEBUG_USER_ID` read it; `--env` repeats and a later file wins.
3. A local `.smig/` takes over until `--global` or `smig config local off`, and never holds a secret: `pgpassword`, `github_token`, `ssh_key`, `ssh_key_password` and `anthropic_api_key` live in `~/.smig/config.yaml`.
4. Every long value flag takes its value with an equals sign: `--env=.env.prd`, `--config=prd`, `--to=prd`, never `--env .env.prd`. The spaced form is rejected by `requireEqualsFlags` in `internal/migrate/root.go`.
5. A consumer justfile with `set dotenv-load` injects that repo's `.env` first, and a variable already set in the process wins over an `--env` file. So `--env=.env.prd` through a `just migrate` recipe is a no op that targets local. Call the binary directly with `--schema` and `--db-dir`.
6. `smig config get` prints the active config and the layer of every value, secrets masked; `smig config set --to=prd pghost=... pgdatabase=... protected=true` writes a named config at mode 0600, `--local` writes the local `.smig/`, and `config use`, `list`, `init`, `local on|off` and `path` do the rest.
7. On a `protected` config every write command prints its plan and asks for `yes`, `destroy` and `down` ask for the config name, and a pipe or an mcp call needs `--yes`. `--plan` prints the plan of a write and stops.
8. Persistent flags: `--schema`, `--db-dir`, `--config`, `--env`, `--global`, `--yes`, `--plan`, `--force`, `-s` or `--silent`, `-v`, `-vv`, `--extremely-verbose`, `--json`, and `--anthropic-key` and `--model` for `down`.

```yaml
default: local
configs:
  local:
    pghost: localhost
    pgport: "5436"
    pguser: postgres
    pgdatabase: nimployer
  prd:
    pghost: pq-prd-nimployer.postgres.database.azure.com
    pgdatabase: nimployer
    pgsslmode: require
    protected: "true"
```

## Hard rules

1. Never bypass `boot_check`. When `up` refuses, run `upgrade` locally.
2. Never run `down`, `merge --apply` or `merge --revert` without showing the user what will change first.
3. Never apply a reconcile remediation marked `destructive` or `review` without explicit confirmation.
4. Never run `destroy` without `--dry-run` first and explicit confirmation, and never when the dry run reports build errors.
5. Run write commands with the same env as the real deploy. A wrong `PGDATABASE` writes to the wrong server.
6. Run `stat` before any write, and remember `check` writes.
7. `insert` writes rows; confirm `PGDATABASE` first.

## mcp

1. `smig mcp` serves every command but `mcp`, `skill`, `plugin`, `completion`, `config`, `version` and `help` as a tool over stdio, named by its path, positional arguments as `args`, flags as `flags`. `stat`, `lint`, `reconcile` and `test` are read only tools, `down` and `destroy` destructive, the rest write.
2. A tool call runs `smig` in the directory claude was started in, with the same environment, `--env=<file>` layers, local `.smig/` and named config.
3. Each file `up`, `run` or `rebase` applies is a step; a host that renders MCP Apps shows them live with the result on `ui://smig/run`.

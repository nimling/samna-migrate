# Authoring a step file and its SQL

Load this when writing `migrate.yml`, naming a SQL file, or wiring an include that pulls SQL from somewhere else.

## Step types

Every step declares a `type`, required, one of:

1. `base` for baseline DDL.

2. `migration` for schema migrations.

3. `seed` for non DDL seeded data.

A `base` or `seed` step also declares a `slug` naming the area it deploys to. A `migration` step declares no slug, because each of its files targets an area owned by another step.

`Load` rejects a missing or invalid type, a slug on a migration step, and a missing slug on a base or seed step.

A step may carry an `if` shell condition. When it is false the step is skipped and its files are never resolved, so they are never linted and never applied.

## Filename grammar

`V<version>__<slug>_<name>.sql`

1. A `V` prefix.

2. A dot separated integer version whose leading component is at least 1.

3. The `__` separator.

4. A lowercase alphanumeric slug.

5. A single underscore.

6. A `<name>` of lowercase alphanumerics and underscores.

Slug and name are both required and the version never starts at 0. The slug must be one of the slugs declared by the steps in `migrate.yml`, and a multi word declared slug such as `debug_user` owns any name beginning `debug_user_`.

With steps declaring `claimius` and `base`, `V1.0__claimius_roles.sql` is valid, while `V1.0__roles.sql`, `V0.0__claimius_roles.sql`, and `V1.0__widget_roles.sql` are all rejected.

The slug names the area the file changes, never a verb. `ParseFilename` and `Config.Slugs` in `internal/steps/steps.go` carry the grammar, `lint` enforces it.

## Ordering

Files sort by parsed version, component by component, so `V1.2` precedes `V1.10`. A filename that fails to parse falls back to a raw string sort, which puts `V1.10` ahead of `V1.2`. Fixing a filename therefore changes apply order on a fresh build. Check that no file drops what an earlier file creates before and after a rename.

## Identity in the ledger

A file is identified by its path relative to the database directory, at `internal/preflight/preflight.go:57`. There is no rename detection.

So a rename, including a folder rename, makes the file new to every server. `up` will apply it again, which for a seed means re executing it. Pair any rename with `rebase <path>...` on each server for the files whose content is already deployed, and leave out only the ones you genuinely want to run.

## Include resolution

An include entry resolves from a local folder, a git repo, or a url.

1. Local. `path`, with an optional `fallback`. A local include that is missing is skipped.

2. Git. `git` for the repo, `branch` for the branch to track, `ref` for a tag or commit to pin, `token` for https auth, `key` for ssh auth, `path` for the subfolder inside the repo. smig shallow clones the ref in process with go-git and reads only that subfolder, so no `git` binary is required. `ref` wins when set, otherwise `branch`, and `branch` defaults to `main`, so an entry with only `git` and `path` tracks the latest `main`.

3. Url. `url` to an archive, with `path` as the subfolder inside it.

A git or url include that fails to resolve is a hard error, which stops every command including `lint`.

For https a private repo uses `token`, or `GITHUB_TOKEN` when `token` is unset. For ssh, `key` or `SMIG_SSH_KEY` is a key file path or inline key material with an optional `SMIG_SSH_KEY_PASSWORD`; with no key set smig prefers a default `~/.ssh` key file and falls back to the ssh agent.

Every remote field is environment expanded, so `ref: $MIDDLEWARE_VERSION` reads from the env loaded for the run. Resolution lives in `internal/steps/steps.go`.

```yaml
include:
  - git: git@github.com:nimling/samna-auth-middleware.git
    ref: v1.1.0-alpha0007
    path: prophet/database
```

## SQL shape

1. No `session_replication_role`. Triggers are the contract.

2. `COMMENT ON FUNCTION` always carries the argument signature, so it survives an overload.

3. `CREATE TYPE` carries a `pg_type` or `duplicate_object` guard, so a reapply does not fail.

4. In migration files, `CREATE INDEX`, `ADD COLUMN`, and `CREATE FUNCTION` use their idempotent forms.

5. A base or seed file is replayed whenever its sha drifts, so it must be safe to run more than once.

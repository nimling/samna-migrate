---
name: smig-reconcile
description: Reconciles a service's database against its migration tree and folds every file under its `migrations/` back into the `base/` step. Use when a deployed database and the tree have drifted apart, when a reconcile report has to become the tree's next shape, when `migrations/` is to be emptied into `base/`, or when the ledger of a deployed database must be told a fold happened. Not for running a single smig command, which is the smig skill.
argument-hint: [reconcile|fold] [env]
allowed-tools: Bash(smig *)
---

The procedure that brings a consuming repo's tree and its databases to one shape, and the fold that leaves `base/` as the whole current schema. The commands, flags and the reconcile report are the `smig` skill and its `references/reconcile.md`; the tree rules are `database.md`, and the deployed procedures and the fold follow-up are `migrations.md` rules 3, 5.1 and 6 to 13, both under `~/.claude/rules/`. No smig command folds a migration body into a base file: the fold is written by hand, and smig proves it.

## Reconcile

1. Read the deployed state with `stat` and `reconcile --db`, from a plain shell with `--env=.env.<env>` as `migrations.md` rule 3 says.
2. Restore that database into a local container, `upgrade` it, and `reconcile --db` the tree against the copy. Read the header first; a build error makes every only in live verdict `review`, never `drop`.
3. Author the corrective SQL from the JSON `remediation`, `phase` and `desired_sql`, as `migrations.md` rules 8 to 10 say, and run it against the copy until `reconcile --db` reads clean except the expected partitions.
4. A remediation marked `destructive` or `review` waits for the user's confirmation.

## Fold migrations into base

Done when `migrations/` holds no file, `base/` builds the same schema alone, and every deployed ledger shows no applied row whose file is absent.

1. Take the list: every file under the repo's `database/migrations/`, in version order.
2. For each, edit the `base/` file that owns the area so it carries the end state the migration produced: a column the migration added is a column of the `CREATE TABLE`, a changed function is the new body, a renamed or dropped object is gone from base. Every statement stays re runnable (`database.md` 2, 3). A backfill or a one off data fix is not schema and is dropped with its file.
3. Prove it on a build from nothing: `just build-db`, then `up` on an empty database, then `reconcile --db` of the folded tree against a restored copy of each deployed database. The only differences left are the expected partitions.
4. Hand the user the exact `rm` of every folded migration file; a session never deletes one.
5. Per deployed database, tst then prd, from a plain shell: `upgrade`, `up`, `rebase --prune=migration`, `rebase --prune=claimius` where the include moved, then `stat` (`migrations.md` rule 5.1). A server this machine cannot reach is handed to the user.
6. Commit the base edits and the removals in one commit; the first release on the folded tree comes after every deployed ledger is pruned, or the pipeline stops on "applied but absent from the source tree".

## Verify

1. `smig lint` passes.
2. `reconcile --db` against each deployed database reads clean except the expected partitions.
3. `stat` on each shows no applied row whose file is absent.

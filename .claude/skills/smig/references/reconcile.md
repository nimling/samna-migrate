# reconcile

Load this when comparing a tree against a live server, reading a reconcile report, or turning its JSON into corrective SQL.

`reconcile` is read only against the live server.

## The four sections

All four run when none is named.

1. `--files` compares each local `.sql` against the body stored in the ledger at apply time, classified added, dropped, changed, or reordered.

2. `--objects` tracks every created object for moves, renames, signature, content, and position changes.

3. `--git` shows the real `git diff` of each changed, dropped, or reordered file since the commit it was deployed from, when the folder is a git repo.

4. `--db` builds every local file into a fresh docker postgres and diffs the produced objects against the live server across functions, tables and columns, constraints, indexes, triggers, views, types, sequences, grants, and comments. Needs docker. This is the only section that reads true live DDL.

Other flags: `--json` is the output format and is orthogonal to the sections, where bare `--json` emits the joint and `--db --json` emits only the database comparison. `--keep` leaves the container and candidate tree for inspection. `--image` overrides the postgres image, which otherwise follows the live server major version. `--stop-one-error` stops the file audit at the first difference.

## Reading the report

Read the header line first: `deployed N of M files into the container, K build errors`.

When K is nonzero the only in live list is suspect, because a file that failed to build never produced its objects, so they surface as only in live without being live only drift. In that case every only in live verdict is downgraded from `drop` to `review`. Never drop on a partial build. Resolve the build errors and re run.

Then read the three buckets:

1. `produced, not in live` means the tree is ahead of live.

2. `only in live` means live holds objects the tree does not build, or the build failed.

3. `definition differs` means the materialised DDL drifted.

Extension owned objects, found through `pg_depend`, are recognised and never reported as drop on live.

## The JSON contract

Each object carries what is needed to author corrective SQL with no guessing.

1. `remediation` is the direction: `create`, `drop`, `update`, `review`, `none`.

2. `phase` is the apply order: extension, schema, type, table, sequence, function, view, index, constraint, trigger, policy, grant, comment. Emit statements in ascending phase.

3. `destructive` flags a drop or a dropped column. Surface these to the user before applying.

4. `desired_sql` is what the target should hold, `current_live_ddl` is what it holds now. Tables also carry `columns[]` with per column `add`, `alter`, or `drop` plus the `live` and `built` definitions.

## Fidelity per kind

These come from postgres introspection, so how much of a statement you get varies.

1. Function, index, trigger arrive as complete runnable statements. Use them directly.

2. Constraint is the body only. Wrap it in `ALTER TABLE ... ADD CONSTRAINT`.

3. Table is a column list, not a `CREATE TABLE`. Build the `ALTER TABLE` from `columns[]`.

4. View is the query only. Wrap it in `CREATE OR REPLACE VIEW`.

5. Sequence, enum, grant, and comment are summary strings. Reconstruct the statement from the fields.

5.1. Grant. `signature` is `function <schema>.<fn>(<args>) <grantee>` and `desired_sql` is the privilege, for example `EXECUTE`. On `create` emit `GRANT <privilege> ON FUNCTION <schema>.<fn>(<args>) TO <grantee>`. On `drop` or `review` emit the matching `REVOKE`. The grantee is the trailing token of the identity, and `public` maps to `PUBLIC`.

5.2. Comment. `signature` is `function <schema>.<fn>(<args>)` and `desired_sql` is the comment text. On `create` emit `COMMENT ON FUNCTION <schema>.<fn>(<args>) IS '<text>'`. On `drop` or `review` emit `IS NULL`.

5.3. Sequence and enum summaries carry data_type, start, increment, or the label list. They omit min, max, cache, ownership, storage, and collation. When a diff lands on one of those, introspect that single object for the missing detail before authoring the `ALTER`.

## Worked example

```
smig reconcile --db --env=.env.prd --schema=./database/migrate.yml --db-dir=./database
```

Read the header, then the three buckets, then add `--json` to lift the fields above and synthesise the SQL that makes the two servers match.

A signature change shows up as a matched pair, the new signature under `produced, not in live` and the current one under `only in live`, together with its grants and its comment. Treat the pair as one change, and check the defining file already drops the current signature before creating the new one, otherwise both overloads survive the apply.

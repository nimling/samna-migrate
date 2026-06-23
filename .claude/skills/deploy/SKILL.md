---
name: deploy
description: Test, build, commit, push, tag, and install a new version of the smig CLI so the Go module tag and the locally installed binary stay in sync.
---

# deploy

Ship a new version of `smig`. The repo publishes one artefact: the Go module `github.com/nimling/samna-migrate`, consumed via `go get` by tag and installed locally with `just install`. Deploying requires a git repository with an `origin` remote; `sbump` commits the version bump and pushes the tag.

When the user says "deploy" in this repo, execute these steps in order. Stop on the first failure and surface the error.

## 1. Write or update tests for meaningful parts of the change

Look at the diff with `git diff` and `git status` and identify the observable surface. Pure logic gets a package level `_test.go` beside the code, postgres dependent paths get a case under `test/integration/`, CLI level behaviour gets a case under `test/e2e/`. Trivial moves and rename only diffs do not need a new test. Anything that changes a command's exit behaviour, a ledger write, a preflight verdict, a reconcile verdict, a lockfile shape, or a samna_migrate schema step MUST be covered.

The test must assert the observable contract, not the internal call graph.

## 2. Run the unit tests and vet

```
just test
just vet
```

Failure: report the failing names and stop. Do not commit, do not bump.

## 3. Run the docker suites when the change warrants it

When the diff touches `internal/apply`, `internal/preflight`, `internal/upgrade`, `internal/merge`, `internal/reconcile`, or `internal/schema`:

```
just test-integration
just test-e2e
```

Both need docker running and the `../bookable_server_test/` sibling checkout. Failure: report and stop.

## 4. Build

```
just build
```

Produces `bin/smig` with version ldflags. Failure: report the build output and stop.

## 5. Schema chain check

If the diff adds or changes anything under `internal/upgrade/sql/`, confirm `SchemaVersion` in `pkg/cli/` was bumped and the new `upgrade_to_<n>.sql` is wired into the switch in `internal/upgrade/upgrade.go`. A schema change without the version bump bricks every consumer's boot check.

## 6. Commit and push

Stage every changed file relevant to the release. Write a single sentence describing the user visible change. Push to `origin/main`.

```
git add -A
git commit -m "<one sentence describing the change>"
git push
```

## 7. Bump and tag

```
just deploy
```

Calls `../sbump/sbump.sh patch --env APP_VERSION --push-version`. Patch bump, tag write, tag push. Consumers pick the new tag up via `go get github.com/nimling/samna-migrate@vX.Y.Z`.

For minor or major releases, use the explicit `major|minor|patch` argument on `sbump.sh` instead of `patch`. A `SchemaVersion` bump is always at least a minor.

## 8. Install locally

```
just install
```

Replaces the `smig` in `GOPATH/bin` so the operator's local binary matches the tag that just shipped.

## Never

1. Skip steps 1, 2, or 4. A missing test, a failing test, a vet finding, or a failing build must block the deploy.

2. Edit `APP_VERSION` in `.env` by hand. `sbump` owns that field.

3. Tag manually or push tags manually. `just deploy` is the single tagging path.

4. Use `--no-verify` or `--no-gpg-sign`.

5. Ship a samna_migrate schema step without its `SchemaVersion` bump.

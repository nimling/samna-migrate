---
name: test
description: Runs the smig tests. The Go unit tests with no docker, and the e2e and integration suites against a fake bookable postgres built from database/smig with the smig binary at image init. Use when asked to test, verify or prove a change to the smig cli in this repo. Not for running smig against a database, which is the smig skill, not for starting the test database to work against, which is the run skill, and not for releasing, which is the deploy skill.
argument-hint: [go|docker] [<TestName>]
allowed-tools: Bash(just *), Bash(docker *)
---

The tests of the smig cli through its `justfile`. Driving smig is the `smig` skill; the database on its own is the `run` skill; releasing is the `deploy` skill. Where tests go is `.claude/rules/deploy.md` Tests.

## Recipes

1. `just test` runs `test-go`, then `test-docker`. One test: `just test <TestName>` passes the name to both, which add `-run <TestName>` to every `go test`; `just test-go <TestName>` and `just test-docker <TestName>` take it the same way.
2. `just test-go` runs `go test ./...`: the `_test.go` files beside the code. No docker, no database.
3. `just test-docker` runs `just build` for `bin/smig`, builds `database/smig/Dockerfile` into the `bookable-smig-db` image, starts it as container `bookable-smig-db` on `DB_PORT` (default 5436, overridable in `.env`) with volume `bookable-smig-db-data`, waits for `pg_isready`, then runs `./test/e2e/...` with `-tags=e2e` and `./test/integration/...` with `-tags=integration` as user, password and database `bookable`. The container and volume are removed on exit.
4. Passes means every package `ok` and exit 0. A failure prints the test name and the file line; report them and stop.

## Failures

1. `test-docker` needs docker running; a refused `docker build` or `docker run` is that.
2. Port 5436 in use: set `DB_PORT` in `.env` to a free port.
3. A container left by a killed run is removed by the next run's `docker rm -f bookable-smig-db`.
4. The image init runs `smig upgrade` then `smig up` over `database/smig/migrate.yml`; a failing step shows in `docker logs bookable-smig-db` before the wait times out.

## Not run here

1. `test/live/` needs `-tags=live` and `ANTHROPIC_API_KEY`, and no recipe runs it.
2. `smig test`, the command this cli ships, is never run as part of testing in any repo, this one included: `../.claude/rules/platform.md` Testing 2.
3. The comments in `test/e2e/e2e_test.go` name `just build-db-smig` and `just build-db-shell`; neither recipe exists, and `database/shell` has no recipe.

## A change

1. Cover anything that changes exit behaviour, a ledger write, a preflight or reconcile verdict, or a `samna_migrate` schema step: `.claude/rules/deploy.md` Tests 3.
2. Pure logic gets a `_test.go` beside the code, a postgres path a case under `test/integration/`, cli behaviour a case under `test/e2e/`.

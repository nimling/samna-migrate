---
name: run
description: Builds and runs the smig cli from this checkout. bin/smig with the version ldflags, the installed smig on GOPATH/bin, and the fake bookable postgres from database/smig that the docker tests use, started by hand to try a command against. Use when asked to build, install, run or try a change to smig locally. Not for what each smig command does, which is the smig skill, not for the test suites, which is the test skill, and not for releasing, which is the deploy skill.
argument-hint: [build|install|db]
allowed-tools: Bash(just *), Bash(docker *), Bash(./bin/smig *)
---

Running this checkout's smig on the local machine. What a command does is the `smig` skill; the suites are the `test` skill.

## Binary

1. `just build` writes `bin/smig` with `Version`, `BuildTime` and `GitCommit` in `pkg/cli` from the ldflags; `APP_VERSION` comes from `.env` or `git describe`.
2. Try a change with `./bin/smig <command>`; `./bin/smig version` shows what was built.
3. `just install` builds and installs `bin/smig` as `GOPATH/bin/smig`, replacing the released one every other repo runs. Do it after a release, or when the user asks to run the checkout everywhere.

## Database

1. No recipe starts the database alone; `just test-docker` builds and removes it. To keep one, run the recipe's own steps: `docker build --build-arg APP_NAME=bookable --build-arg PGPORT=5432 -f database/smig/Dockerfile -t bookable-smig-db .`, then `docker run -d --name bookable-smig-db -p 5436:5432 -e SAUTH_APP_SLUG=bookable bookable-smig-db`.
2. The image init runs the image's own `smig upgrade --yes` and `smig up` over `database/smig/migrate.yml`; wait until `docker exec bookable-smig-db pg_isready -h 127.0.0.1 -U bookable` answers.
3. Point a command at it with `PGHOST=localhost PGPORT=5436 PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable PGSSLMODE=disable ./bin/smig stat --schema=database/smig/migrate.yml --db-dir=database/smig`.
4. Stop with `docker rm -f bookable-smig-db`.
5. A command that writes, `up`, `run`, `rebase`, `check`, `insert` or `destroy`, goes against this container, never a shared server: the `smig` skill Hard rules.

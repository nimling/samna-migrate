set dotenv-load

APP_VERSION := env_var_or_default('APP_VERSION', `git describe --tags --always --dirty 2>/dev/null || echo dev`)
BUILD_TIME := `date -u '+%Y-%m-%d_%H:%M:%S'`
GIT_COMMIT := `git rev-parse --short HEAD 2>/dev/null || echo unknown`
LDFLAGS := "-ldflags \"-X github.com/nimling/samna-migrate/pkg/cli.Version=" + APP_VERSION + " -X github.com/nimling/samna-migrate/pkg/cli.BuildTime=" + BUILD_TIME + " -X github.com/nimling/samna-migrate/pkg/cli.GitCommit=" + GIT_COMMIT + "\""

DB_IMAGE := "bookable-smig-db"
DB_NAME  := "bookable-smig-db"
DB_PORT  := env_var_or_default('DB_PORT', '5436')

default:
    @just --list

build:
    go build {{LDFLAGS}} -o bin/smig ./cmd

deploy level="patch":
    @sbump {{level}} --env APP_VERSION --yaml ./action.yml@.inputs.smig-version.default --push-version --workflow

# Run every test: the go tests and the docker tests.
test: test-go test-docker

# Run only the go tests, no docker.
test-go:
    go test ./...

# Run the docker tests: build a fake bookable postgres with the smig tool at
# image init, then run the tool's docker-backed suites against it. Needs docker.
test-docker: build
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'docker rm -f {{DB_NAME}} >/dev/null 2>&1 || true; docker volume rm {{DB_NAME}}-data >/dev/null 2>&1 || true' EXIT
    docker rm -f {{DB_NAME}} >/dev/null 2>&1 || true
    docker volume rm {{DB_NAME}}-data >/dev/null 2>&1 || true
    docker build --build-arg APP_NAME=bookable --build-arg PGPORT=5432 -f database/smig/Dockerfile -t {{DB_IMAGE}} .
    docker volume create {{DB_NAME}}-data >/dev/null
    docker run -d --name {{DB_NAME}} -p {{DB_PORT}}:5432 -e SAUTH_APP_SLUG=bookable -v {{DB_NAME}}-data:/var/lib/postgresql/data {{DB_IMAGE}} >/dev/null
    for i in $(seq 1 150); do docker exec {{DB_NAME}} pg_isready -h 127.0.0.1 -U bookable >/dev/null 2>&1 && break; sleep 2; done
    PGHOST=localhost PGPORT={{DB_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/e2e/... -tags=e2e -count=1
    PGHOST=localhost PGPORT={{DB_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/integration/... -tags=integration -count=1

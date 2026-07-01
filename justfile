set dotenv-load

APP_VERSION := env_var_or_default('APP_VERSION', `git describe --tags --always --dirty 2>/dev/null || echo dev`)
BUILD_TIME := `date -u '+%Y-%m-%d_%H:%M:%S'`
GIT_COMMIT := `git rev-parse --short HEAD 2>/dev/null || echo unknown`
LDFLAGS := "-ldflags \"-X github.com/nimling/samna-migrate/pkg/cli.Version=" + APP_VERSION + " -X github.com/nimling/samna-migrate/pkg/cli.BuildTime=" + BUILD_TIME + " -X github.com/nimling/samna-migrate/pkg/cli.GitCommit=" + GIT_COMMIT + "\""

DB_SHELL_IMAGE := "bookable-shell-db"
DB_SHELL_NAME  := "bookable-shell-db"
DB_SHELL_PORT  := "5435"

DB_SMIG_IMAGE  := "bookable-smig-db"
DB_SMIG_NAME   := "bookable-smig-db"
DB_SMIG_PORT   := "5436"

default:
    @just --list

build:
    go build {{LDFLAGS}} -o bin/smig ./cmd

install: build
    rm -f `go env GOPATH`/bin/smig
    install -m 755 bin/smig `go env GOPATH`/bin/smig
    go install github.com/nimling/sbump/cmd@latest
    mv "$(go env GOPATH)/bin/cmd" "$(go env GOPATH)/bin/sbump"

clean:
    rm -rf bin/

deps:
    go mod tidy

vet:
    go vet ./...

fmt:
    go fmt ./...

# Run every go test suite: unit, integration, e2e against both test databases, and
# live. Pass NAME to filter to a single test via -run across all suites. Needs docker.
test name="": build build-db
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'just db-down' EXIT
    RUN=""
    [ -n "{{name}}" ] && RUN="-run {{name}}"
    go test ./... $RUN
    PGHOST=localhost PGPORT={{DB_SHELL_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/integration/... -tags=integration -count=1 $RUN
    PGHOST=localhost PGPORT={{DB_SMIG_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/e2e/... -tags=e2e -count=1 $RUN
    PGHOST=localhost PGPORT={{DB_SHELL_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/e2e/... -tags=e2e -count=1 $RUN
    go test ./test/live/... -tags=live $RUN

# Build the shell test db image from database/shell and start it on DB_SHELL_PORT.
# Image entrypoint runs database/shell/scripts/migrate.sh against migrate.yml.
build-db-shell:
    @docker rm -f {{DB_SHELL_NAME}} > /dev/null 2>&1 || true
    @docker volume rm {{DB_SHELL_NAME}}-data > /dev/null 2>&1 || true
    @docker rmi -f {{DB_SHELL_IMAGE}} > /dev/null 2>&1 || true
    @echo "Building {{DB_SHELL_IMAGE}} image..."
    @docker build --no-cache \
        --build-arg APP_NAME=bookable --build-arg PGPORT=5432 \
        -t {{DB_SHELL_IMAGE}} database/shell
    @docker volume create {{DB_SHELL_NAME}}-data
    @echo "Starting {{DB_SHELL_NAME}} on port {{DB_SHELL_PORT}}..."
    @docker run -d --name {{DB_SHELL_NAME}} \
        -p {{DB_SHELL_PORT}}:5432 \
        -e SAUTH_APP_SLUG=bookable \
        -v {{DB_SHELL_NAME}}-data:/var/lib/postgresql/data \
        {{DB_SHELL_IMAGE}}
    @echo "Waiting for {{DB_SHELL_NAME}} migrations to finish..."
    @sh -c 'for i in $(seq 1 150); do docker exec {{DB_SHELL_NAME}} pg_isready -h 127.0.0.1 -U bookable > /dev/null 2>&1 && exit 0; sleep 2; done; echo "{{DB_SHELL_NAME}} not ready after 300s"; docker logs --tail 30 {{DB_SHELL_NAME}}; exit 1'

# Build the smig test db image from database/smig and start it on DB_SMIG_PORT.
# Multi-stage Dockerfile builds the smig binary from the migrate Go source.
# Image entrypoint runs smig upgrade then smig up against the same migrate.yml.
build-db-smig:
    @docker rm -f {{DB_SMIG_NAME}} > /dev/null 2>&1 || true
    @docker volume rm {{DB_SMIG_NAME}}-data > /dev/null 2>&1 || true
    @docker rmi -f {{DB_SMIG_IMAGE}} > /dev/null 2>&1 || true
    @echo "Building {{DB_SMIG_IMAGE}} image..."
    @docker build --no-cache \
        --build-arg APP_NAME=bookable --build-arg PGPORT=5432 \
        -f database/smig/Dockerfile \
        -t {{DB_SMIG_IMAGE}} .
    @docker volume create {{DB_SMIG_NAME}}-data
    @echo "Starting {{DB_SMIG_NAME}} on port {{DB_SMIG_PORT}}..."
    @docker run -d --name {{DB_SMIG_NAME}} \
        -p {{DB_SMIG_PORT}}:5432 \
        -e SAUTH_APP_SLUG=bookable \
        -v {{DB_SMIG_NAME}}-data:/var/lib/postgresql/data \
        {{DB_SMIG_IMAGE}}
    @echo "Waiting for {{DB_SMIG_NAME}} migrations to finish..."
    @sh -c 'for i in $(seq 1 150); do docker exec {{DB_SMIG_NAME}} pg_isready -h 127.0.0.1 -U bookable > /dev/null 2>&1 && exit 0; sleep 2; done; echo "{{DB_SMIG_NAME}} not ready after 300s"; docker logs --tail 30 {{DB_SMIG_NAME}}; exit 1'

# Build and run both test databases side by side.
build-db: build-db-shell build-db-smig

# Tear down both test databases.
db-down:
    @docker rm -f {{DB_SHELL_NAME}} > /dev/null 2>&1 || true
    @docker volume rm {{DB_SHELL_NAME}}-data > /dev/null 2>&1 || true
    @docker rm -f {{DB_SMIG_NAME}} > /dev/null 2>&1 || true
    @docker volume rm {{DB_SMIG_NAME}}-data > /dev/null 2>&1 || true

dev *args:
    go run ./cmd {{args}}

deploy level="patch":
    @sbump {{level}} --env APP_VERSION --yaml ./action.yml@.inputs.smig-version.default --push-version --workflow

help:
    @echo "Available targets:"
    @echo "  build              - Build the smig binary"
    @echo "  install            - Install smig to GOPATH/bin"
    @echo "  test [NAME]        - Run every suite: unit, integration, e2e, live. NAME filters one test. Needs docker"
    @echo "  build-db-shell     - Build + run shell-managed bookable db on {{DB_SHELL_PORT}}"
    @echo "  build-db-smig      - Build + run smig-managed bookable db on {{DB_SMIG_PORT}}"
    @echo "  build-db           - Build + run both side by side"
    @echo "  db-down            - Tear down both test databases"
    @echo "  dev <args>         - Run smig locally"

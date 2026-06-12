set dotenv-load

APP_VERSION := env_var_or_default('APP_VERSION', `git describe --tags --always --dirty 2>/dev/null || echo dev`)
BUILD_TIME := `date -u '+%Y-%m-%d_%H:%M:%S'`
GIT_COMMIT := `git rev-parse --short HEAD 2>/dev/null || echo unknown`
LDFLAGS := "-ldflags \"-X github.com/nimling/samna-migrate/pkg/cli.Version=" + APP_VERSION + " -X github.com/nimling/samna-migrate/pkg/cli.BuildTime=" + BUILD_TIME + " -X github.com/nimling/samna-migrate/pkg/cli.GitCommit=" + GIT_COMMIT + "\""

DB_SHELL_IMAGE := "bookable-shell-db"
DB_SHELL_NAME  := "bookable-shell-db"
DB_SHELL_PORT  := "5433"

DB_SMIG_IMAGE  := "bookable-smig-db"
DB_SMIG_NAME   := "bookable-smig-db"
DB_SMIG_PORT   := "5434"

default:
    @just --list

build:
    go build {{LDFLAGS}} -o bin/smig ./cmd

install: build
    rm -f `go env GOPATH`/bin/smig
    install -m 755 bin/smig `go env GOPATH`/bin/smig

clean:
    rm -rf bin/

deps:
    go mod tidy

vet:
    go vet ./...

fmt:
    go fmt ./...

# Run go tests (unit).
test:
    go test ./...

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
        -v {{DB_SHELL_NAME}}-data:/var/lib/postgresql/data \
        {{DB_SHELL_IMAGE}}
    @sleep 3

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
        -v {{DB_SMIG_NAME}}-data:/var/lib/postgresql/data \
        {{DB_SMIG_IMAGE}}
    @sleep 3

# Build and run both test databases side by side.
build-db: build-db-shell build-db-smig

# Tear down both test databases.
db-down:
    @docker rm -f {{DB_SHELL_NAME}} > /dev/null 2>&1 || true
    @docker volume rm {{DB_SHELL_NAME}}-data > /dev/null 2>&1 || true
    @docker rm -f {{DB_SMIG_NAME}} > /dev/null 2>&1 || true
    @docker volume rm {{DB_SMIG_NAME}}-data > /dev/null 2>&1 || true

# Run integration tests against the shell test db (samna_migrate is dropped per
# test, so this exercises smig taking over a database whose forward migrations
# are physically applied by the shell tool).
test-integration: build-db-shell
    PGHOST=localhost PGPORT={{DB_SHELL_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/integration/... -tags=integration -count=1
    @just db-down

# Run end-to-end smig CLI tests against the smig test db (entrypoint has already
# applied migrations via smig upgrade + smig up, so schema_version=3 from the start).
test-e2e: build build-db-smig
    PGHOST=localhost PGPORT={{DB_SMIG_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/e2e/... -tags=e2e -count=1 -v
    @just db-down

# Run e2e tests against the shell-managed database. Verifies that smig can take
# over a database where samna_migrate.state was set up by the shell migrate.sh.
test-e2e-shell: build build-db-shell
    PGHOST=localhost PGPORT={{DB_SHELL_PORT}} PGUSER=bookable PGPASSWORD=bookable PGDATABASE=bookable \
        go test ./test/e2e/... -tags=e2e -count=1 -v
    @just db-down

# Run live tests against the real Anthropic API (requires ANTHROPIC_API_KEY).
test-live:
    go test ./test/live/... -tags=live

dev *args:
    go run ./cmd {{args}}

deploy:
    @../sbump/sbump.sh patch --env APP_VERSION --push-version

help:
    @echo "Available targets:"
    @echo "  build              - Build the smig binary"
    @echo "  install            - Install smig to GOPATH/bin"
    @echo "  test               - Run unit tests"
    @echo "  build-db-shell     - Build + run shell-managed bookable db on {{DB_SHELL_PORT}}"
    @echo "  build-db-smig      - Build + run smig-managed bookable db on {{DB_SMIG_PORT}}"
    @echo "  build-db           - Build + run both side by side"
    @echo "  db-down            - Tear down both test databases"
    @echo "  test-integration   - Integration tests against shell-managed db"
    @echo "  test-e2e           - End-to-end CLI tests against smig-managed db"
    @echo "  test-e2e-shell     - End-to-end CLI tests against shell-managed db"
    @echo "  test-live          - Live Anthropic API tests (needs ANTHROPIC_API_KEY)"
    @echo "  dev <args>         - Run smig locally"

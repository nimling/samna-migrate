package migrate

import (
	nimcli "github.com/nimling/nimbody/cli"
)

var settings = &nimcli.Settings{Name: "smig", Prefix: "SMIG_", Keys: []nimcli.Setting{
	{Key: "pghost", Env: "PGHOST"},
	{Key: "pgport", Env: "PGPORT"},
	{Key: "pguser", Env: "PGUSER"},
	{Key: "pgpassword", Env: "PGPASSWORD", Secret: true},
	{Key: "pgdatabase", Env: "PGDATABASE"},
	{Key: "pgsslmode", Env: "PGSSLMODE"},
	{Key: "migrate_schema", Env: "MIGRATE_SCHEMA", Flag: "schema"},
	{Key: "db_dir", Env: "DB_DIR", Flag: "db-dir"},
	{Key: "github_token", Env: "GITHUB_TOKEN", Secret: true},
	{Key: "ssh_key", Env: "SMIG_SSH_KEY", Secret: true},
	{Key: "ssh_key_password", Env: "SMIG_SSH_KEY_PASSWORD", Secret: true},
	{Key: "anthropic_api_key", Env: "ANTHROPIC_API_KEY", Flag: "anthropic-key", Secret: true},
}}

var configCmd = settings.ConfigCommand()

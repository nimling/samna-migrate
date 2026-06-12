package schema

import (
	"context"
	"fmt"

	"github.com/nimling/samna-migrate/internal/db"
)

// Ensure creates the samna_migrate schema and singleton state row if missing.
func Ensure(ctx context.Context, d *db.DB) error {
	_, err := d.Pool.Exec(ctx, `CREATE SCHEMA IF NOT EXISTS samna_migrate`)
	if err != nil {
		return fmt.Errorf("create schema: %w", err)
	}
	_, err = d.Pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS samna_migrate.state (
			id INTEGER PRIMARY KEY,
			version TEXT,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`)
	if err != nil {
		return fmt.Errorf("create state: %w", err)
	}
	_, err = d.Pool.Exec(ctx, `INSERT INTO samna_migrate.state (id) VALUES (1) ON CONFLICT (id) DO NOTHING`)
	return err
}

func GetSchemaVersion(ctx context.Context, d *db.DB) (int, error) {
	exists, _ := d.ColumnExists(ctx, "samna_migrate", "state", "schema_version")
	if !exists {
		return 0, nil
	}
	var v int
	err := d.Pool.QueryRow(ctx, `SELECT COALESCE(schema_version, 0) FROM samna_migrate.state WHERE id = 1`).Scan(&v)
	if err != nil {
		return 0, err
	}
	return v, nil
}

func SetSchemaVersion(ctx context.Context, d *db.DB, v int, toolVersion string) error {
	_, err := d.Pool.Exec(ctx,
		`UPDATE samna_migrate.state SET schema_version = $1, tool_version = $2, updated_at = NOW() WHERE id = 1`,
		v, toolVersion)
	return err
}

func GetToolVersion(ctx context.Context, d *db.DB) (string, error) {
	var v *string
	err := d.Pool.QueryRow(ctx, `SELECT tool_version FROM samna_migrate.state WHERE id = 1`).Scan(&v)
	if err != nil {
		return "", err
	}
	if v == nil {
		return "", nil
	}
	return *v, nil
}

func GetYAMLSha(ctx context.Context, d *db.DB) (string, error) {
	exists, _ := d.ColumnExists(ctx, "samna_migrate", "state", "yaml_sha256")
	if !exists {
		return "", nil
	}
	var v *string
	err := d.Pool.QueryRow(ctx, `SELECT yaml_sha256 FROM samna_migrate.state WHERE id = 1`).Scan(&v)
	if err != nil {
		return "", err
	}
	if v == nil {
		return "", nil
	}
	return *v, nil
}

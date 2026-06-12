//go:build integration

package testdb

import (
	"context"
	"os"
	"testing"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
)

// Open returns a connected DB against the test postgres. Defaults match
// the bookable image (PGPORT=5433 host=localhost user=bookable password=bookable
// dbname=bookable). Overrides via env are respected.
// Cleanup drops samna_migrate so the next test starts fresh while leaving the
// bookable public schema intact.
func Open(t *testing.T) *db.DB {
	t.Helper()
	if v := os.Getenv("PGHOST"); v == "" {
		os.Setenv("PGHOST", "localhost")
	}
	if v := os.Getenv("PGPORT"); v == "" {
		os.Setenv("PGPORT", "5433")
	}
	if v := os.Getenv("PGUSER"); v == "" {
		os.Setenv("PGUSER", "bookable")
	}
	if v := os.Getenv("PGPASSWORD"); v == "" {
		os.Setenv("PGPASSWORD", "bookable")
	}
	if v := os.Getenv("PGDATABASE"); v == "" {
		os.Setenv("PGDATABASE", "bookable")
	}
	if v := os.Getenv("PGSSLMODE"); v == "" {
		os.Setenv("PGSSLMODE", "disable")
	}
	cfg := config.FromEnv()
	d, err := db.Open(context.Background(), cfg)
	if err != nil {
		t.Skipf("test postgres not reachable: %v", err)
	}
	t.Cleanup(func() {
		ctx := context.Background()
		d.Pool.Exec(ctx, `DROP SCHEMA IF EXISTS samna_migrate CASCADE`)
		d.Close()
	})
	return d
}

// Reset drops samna_migrate and recreates the base singleton without invoking
// the upgrade chain. Useful between subtests.
func Reset(t *testing.T, d *db.DB) {
	t.Helper()
	ctx := context.Background()
	d.Pool.Exec(ctx, `DROP SCHEMA IF EXISTS samna_migrate CASCADE`)
}

// EnableUpgradeMode flips the session GUC so writes that the guard trigger
// would otherwise block are permitted. Used in tests that need to set up
// arbitrary samna_migrate.file or history fixtures.
func EnableUpgradeMode(ctx context.Context, d *db.DB) error {
	_, err := d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	return err
}

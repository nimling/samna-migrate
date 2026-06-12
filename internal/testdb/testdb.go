//go:build integration

package testdb

import (
	"context"
	"fmt"
	"os"
	"testing"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
)

// Open returns a connected DB against the test postgres. Defaults match
// the bookable image (PGPORT=5435 host=localhost user=bookable password=bookable
// dbname=bookable). Overrides via env are respected.
// Cleanup drops samna_migrate and every smig_ prefixed fixture table so the
// next test or rerun starts fresh while leaving the bookable public schema
// intact. Test fixtures that create tables must use the smig_ prefix.
func Open(t *testing.T) *db.DB {
	t.Helper()
	if v := os.Getenv("PGHOST"); v == "" {
		os.Setenv("PGHOST", "localhost")
	}
	if v := os.Getenv("PGPORT"); v == "" {
		os.Setenv("PGPORT", "5435")
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
		t.Fatalf("test postgres not reachable on %s:%s, run just build-db-shell first: %v", cfg.PGHost, cfg.PGPort, err)
	}
	dropState(context.Background(), d)
	t.Cleanup(func() {
		dropState(context.Background(), d)
		d.Close()
	})
	return d
}

// Reset drops samna_migrate and the smig_ fixture tables without invoking
// the upgrade chain. Useful between subtests.
func Reset(t *testing.T, d *db.DB) {
	t.Helper()
	dropState(context.Background(), d)
}

func dropState(ctx context.Context, d *db.DB) {
	rows, err := d.Pool.Query(ctx,
		`SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename LIKE 'smig\_%'`)
	if err == nil {
		names := []string{}
		for rows.Next() {
			var n string
			if rows.Scan(&n) == nil {
				names = append(names, n)
			}
		}
		rows.Close()
		for _, n := range names {
			d.Pool.Exec(ctx, fmt.Sprintf(`DROP TABLE IF EXISTS public.%q CASCADE`, n))
		}
	}
	d.Pool.Exec(ctx, `DROP SCHEMA IF EXISTS samna_migrate CASCADE`)
}

// EnableUpgradeMode flips the session GUC so writes that the guard trigger
// would otherwise block are permitted. Used in tests that need to set up
// arbitrary samna_migrate.file or history fixtures.
func EnableUpgradeMode(ctx context.Context, d *db.DB) error {
	_, err := d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	return err
}

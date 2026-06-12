//go:build integration

package integration

import (
	"context"
	"testing"

	"github.com/nimling/samna-migrate/internal/db"
)

func assertConstraint(t *testing.T, d *db.DB, ctx context.Context, name string) {
	t.Helper()
	var n int
	err := d.Pool.QueryRow(ctx, `
		SELECT 1 FROM pg_constraint c
		JOIN pg_namespace n ON n.oid = c.connamespace
		WHERE n.nspname = 'samna_migrate' AND c.conname = $1`, name).Scan(&n)
	if err != nil {
		t.Errorf("constraint missing: %s", name)
	}
}

func assertTrigger(t *testing.T, d *db.DB, ctx context.Context, name string) {
	t.Helper()
	var n int
	err := d.Pool.QueryRow(ctx, `
		SELECT 1 FROM pg_trigger t
		JOIN pg_class c ON c.oid = t.tgrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'samna_migrate' AND t.tgname = $1`, name).Scan(&n)
	if err != nil {
		t.Errorf("trigger missing: %s", name)
	}
}

func assertIndex(t *testing.T, d *db.DB, ctx context.Context, name string) {
	t.Helper()
	var n int
	err := d.Pool.QueryRow(ctx, `
		SELECT 1 FROM pg_indexes
		WHERE schemaname = 'samna_migrate' AND indexname = $1`, name).Scan(&n)
	if err != nil {
		t.Errorf("index missing: %s", name)
	}
}

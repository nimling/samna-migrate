//go:build integration

package integration

import (
	"context"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/testdb"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func TestGuardBlocksPositionUpdate(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	// Seed a row in upgrade mode
	_, err := d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.file (step_name, step_type, slug, file_name, file_path,
		                                 sha256, size_bytes, state, position)
		VALUES ('S', 'base', 'base', 'a.sql', 'base/a.sql', 'deadbeef', 0, 'pending', 1)`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'false'`)
	if err != nil {
		t.Fatal(err)
	}
	// Outside upgrade mode, the position UPDATE should raise
	_, err = d.Pool.Exec(ctx, `UPDATE samna_migrate.file SET position = 999 WHERE file_path = 'base/a.sql'`)
	if err == nil || !strings.Contains(err.Error(), "position is upgrade only") {
		t.Errorf("expected guard block on position, got %v", err)
	}
	// Back in upgrade mode it should work
	_, err = d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `UPDATE samna_migrate.file SET position = 999 WHERE file_path = 'base/a.sql'`)
	if err != nil {
		t.Errorf("upgrade-mode UPDATE failed: %v", err)
	}
}

func TestGuardBlocksHistoryUpdate(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	_, err := d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.history (file_path, sha256, success, action_type, attempt)
		VALUES ('x.sql', 'deadbeef', true, 'apply', 1)`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'false'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `UPDATE samna_migrate.history SET success = false WHERE file_path = 'x.sql'`)
	if err == nil || !strings.Contains(err.Error(), "append only") {
		t.Errorf("expected guard block on history UPDATE, got %v", err)
	}
}

func TestFileAppliedConsistentCheck(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	_, err := d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.file (step_name, step_type, slug, file_name, file_path,
		                                 sha256, size_bytes, state, position, applied_at)
		VALUES ('S', 'base', 'base', 'b.sql', 'base/b.sql', 'deadbeef', 0, 'applied', 2, NULL)`)
	if err == nil || !strings.Contains(err.Error(), "file_applied_consistent") {
		t.Errorf("expected file_applied_consistent CHECK to fire, got %v", err)
	}
}

func TestHistoryActionTypeCheck(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	_, err := d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.history (file_path, sha256, success, action_type)
		VALUES ('x.sql', 'deadbeef', true, 'no_such_action')`)
	if err == nil || !strings.Contains(err.Error(), "action_type") {
		t.Errorf("expected action_type CHECK to fire, got %v", err)
	}
}

//go:build integration

package migrate

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/testdb"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func bootStepsFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "migrate.yml")
	if err := os.WriteFile(path, []byte("name: test\nversion: \"1.0\"\nsteps: []\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestBootCheckAutoInitsFresh(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	steps := bootStepsFile(t)
	if err := bootCheck(ctx, d, steps, filepath.Dir(steps), "smig-test"); err != nil {
		t.Fatalf("bootCheck on fresh database should auto-init, got %v", err)
	}
	v, err := schema.GetSchemaVersion(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	if v != cli.SchemaVersion {
		t.Errorf("schema_version = %d, want %d", v, cli.SchemaVersion)
	}
}

func TestBootCheckBehindRequiresUpgrade(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	steps := bootStepsFile(t)
	if err := bootCheck(ctx, d, steps, filepath.Dir(steps), "smig-test"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `UPDATE samna_migrate.state SET schema_version = 1 WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	err := bootCheck(ctx, d, steps, filepath.Dir(steps), "smig-test")
	if err == nil || !strings.Contains(err.Error(), "schema behind") {
		t.Errorf("expected schema behind error, got %v", err)
	}
}

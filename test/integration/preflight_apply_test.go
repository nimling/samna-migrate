//go:build integration

package integration

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/testdb"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func setupDB(t *testing.T) (*testdb.Ctx, *steps.Config, string) {
	t.Helper()
	return setupWithFiles(t,
		[]fileSeed{
			{rel: "migrations/V1.0__migration_test.sql", body: "CREATE TABLE smig_test_a (id INT);"},
			{rel: "migrations/V1.1__migration_other.sql", body: "CREATE TABLE smig_test_b (id INT);"},
		},
	)
}

type fileSeed struct{ rel, body string }

type testdbWrap struct {
	D     any
	DBDir string
}

func setupWithFiles(t *testing.T, files []fileSeed) (*testdb.Ctx, *steps.Config, string) {
	t.Helper()
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}

	dbDir := t.TempDir()
	migDir := filepath.Join(dbDir, "migrations")
	if err := os.MkdirAll(migDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		abs := filepath.Join(dbDir, f.rel)
		os.MkdirAll(filepath.Dir(abs), 0o755)
		if err := os.WriteFile(abs, []byte(f.body), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	yamlPath := filepath.Join(dbDir, "migrate.yml")
	yaml := `
name: smig-test
steps:
  - name: Migrations
    type: migration
    schemas: [public]
    include:
      - path: migrations/
`
	os.WriteFile(yamlPath, []byte(yaml), 0o644)
	cfg, err := steps.Load(yamlPath)
	if err != nil {
		t.Fatal(err)
	}
	_ = (&testdbWrap{D: d, DBDir: dbDir}) // silence unused for now
	return &testdb.Ctx{D: d, DBDir: dbDir, YAMLPath: yamlPath}, cfg, dbDir
}

func TestPreflightDiscovery(t *testing.T) {
	x, stepsCfg, dbDir := setupDB(t)
	ctx := context.Background()
	snap, err := schema.Snapshot(ctx, x.D, x.YAMLPath)
	if err != nil {
		t.Fatal(err)
	}
	r, err := preflight.Scan(ctx, x.D, snap, stepsCfg, dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if r.FilesNew != 2 {
		t.Errorf("FilesNew = %d, want 2", r.FilesNew)
	}
	// Positions should be sequential starting at 1
	var positions []int
	rows, _ := x.D.Pool.Query(ctx, `SELECT position FROM samna_migrate.file ORDER BY id`)
	defer rows.Close()
	for rows.Next() {
		var p int
		rows.Scan(&p)
		positions = append(positions, p)
	}
	if len(positions) != 2 || positions[0] != 1 || positions[1] != 2 {
		t.Errorf("positions = %v, want [1 2]", positions)
	}
}

func TestApplyHappyPath(t *testing.T) {
	x, stepsCfg, dbDir := setupDB(t)
	ctx := context.Background()
	snap, _ := schema.Snapshot(ctx, x.D, x.YAMLPath)
	if _, err := preflight.Scan(ctx, x.D, snap, stepsCfg, dbDir); err != nil {
		t.Fatal(err)
	}
	pendings, err := apply.ListPending(ctx, x.D)
	if err != nil {
		t.Fatal(err)
	}
	if len(pendings) != 2 {
		t.Fatalf("pending = %d", len(pendings))
	}

	cfg := &config.Config{
		PGHost:     os.Getenv("PGHOST"),
		PGPort:     os.Getenv("PGPORT"),
		PGUser:     os.Getenv("PGUSER"),
		PGPassword: os.Getenv("PGPASSWORD"),
		PGDatabase: os.Getenv("PGDATABASE"),
	}
	_ = cfg
	for _, p := range pendings {
		st, _ := apply.FileRel(stepsCfg, p.FilePath, dbDir)
		if err := apply.File(ctx, x.D, p, st, dbDir, cli.Version,
			os.Getenv("PGUSER"), "localhost", os.Getenv("PGDATABASE")); err != nil {
			t.Fatalf("apply %s: %v", p.FilePath, err)
		}
	}
	var n int
	x.D.Pool.QueryRow(ctx, `SELECT count(*) FROM samna_migrate.file WHERE state='applied' AND step_type='migration'`).Scan(&n)
	if n != 2 {
		t.Errorf("applied count = %d", n)
	}
	x.D.Pool.QueryRow(ctx, `SELECT count(*) FROM samna_migrate.history WHERE action_type='apply'`).Scan(&n)
	if n < 2 {
		t.Errorf("history apply rows = %d", n)
	}
}

package merge

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/steps"
)

func TestFileStatementsSchemaObjects(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "v1.sql")
	content := `
CREATE OR REPLACE FUNCTION public.foo() RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;
CREATE TABLE IF NOT EXISTS public.bar (id INT);
CREATE TYPE public.baz_status AS ENUM ('a','b');
CREATE INDEX foo_idx ON public.bar(id);
`
	os.WriteFile(p, []byte(content), 0o644)
	got, nonSchema, err := fileStatements(p)
	if err != nil {
		t.Fatal(err)
	}
	if nonSchema {
		t.Errorf("pure DDL file must not be flagged non-schema")
	}
	want := map[string]string{
		"foo_idx":           "INDEX",
		"public.bar":        "TABLE",
		"public.baz_status": "TYPE",
		"public.foo":        "FUNCTION",
	}
	for _, g := range got {
		kind, ok := want[g.Name]
		if !ok {
			t.Errorf("unexpected ident: %q", g.Name)
			continue
		}
		if g.Kind != kind {
			t.Errorf("ident %q kind = %q, want %q", g.Name, g.Kind, kind)
		}
		delete(want, g.Name)
	}
	for k := range want {
		t.Errorf("missing ident: %q", k)
	}
}

func TestFileStatementsFlagsNonSchema(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "v2.sql")
	content := `
ALTER TABLE public.bar ADD COLUMN n INT;
INSERT INTO public.bar (id) VALUES (1);
`
	os.WriteFile(p, []byte(content), 0o644)
	got, nonSchema, err := fileStatements(p)
	if err != nil {
		t.Fatal(err)
	}
	if !nonSchema {
		t.Errorf("INSERT must flag the file as carrying non-schema statements")
	}
	var found bool
	for _, g := range got {
		if g.Name == "public.bar" && g.Kind == "TABLE" {
			found = true
		}
	}
	if !found {
		t.Errorf("ALTER TABLE target must still be captured: %v", got)
	}
}

func TestBuildIdentifierRegistry(t *testing.T) {
	dbDir := t.TempDir()
	baseDir := filepath.Join(dbDir, "base")
	migDir := filepath.Join(dbDir, "migrations")
	os.MkdirAll(baseDir, 0o755)
	os.MkdirAll(migDir, 0o755)
	os.WriteFile(filepath.Join(baseDir, "V1.0__base_x.sql"),
		[]byte("CREATE TABLE public.x (id INT);"), 0o644)
	os.WriteFile(filepath.Join(baseDir, "V1.1__base_y.sql"),
		[]byte("CREATE FUNCTION public.y() RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;"), 0o644)
	os.WriteFile(filepath.Join(migDir, "V5.0__add_x_column.sql"),
		[]byte("ALTER TABLE public.x ADD COLUMN n INT;"), 0o644)

	cfg := &steps.Config{Steps: []steps.Step{
		{Name: "Base", Type: "base", Slug: "base", Include: []steps.IncludeEntry{{Path: "base/"}}},
		{Name: "Migrations", Type: "migration", Slug: "migration", Include: []steps.IncludeEntry{{Path: "migrations/"}}},
	}}
	reg, err := buildIdentifierRegistry(cfg, dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if reg["public.x"].Rel == "" {
		t.Errorf("registry missing public.x: %v", reg)
	}
	if reg["public.y"].Rel == "" {
		t.Errorf("registry missing public.y: %v", reg)
	}
}

func TestTreeHashDeterministic(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "a"), 0o755)
	os.MkdirAll(filepath.Join(dir, "b"), 0o755)
	os.WriteFile(filepath.Join(dir, "a", "1.sql"), []byte("SELECT 1"), 0o644)
	os.WriteFile(filepath.Join(dir, "b", "2.sql"), []byte("SELECT 2"), 0o644)
	h1 := treeHash(dir)
	h2 := treeHash(dir)
	if h1 != h2 {
		t.Errorf("treeHash not deterministic: %s vs %s", h1, h2)
	}
	os.WriteFile(filepath.Join(dir, "a", "1.sql"), []byte("SELECT 1 -- changed"), 0o644)
	h3 := treeHash(dir)
	if h3 == h1 {
		t.Error("treeHash did not change after content edit")
	}
}

func TestTreeHashSkipsUpgradedAndMigrate(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, ".upgraded"), 0o755)
	os.MkdirAll(filepath.Join(dir, ".migrate-x"), 0o755)
	os.MkdirAll(filepath.Join(dir, "base"), 0o755)
	os.WriteFile(filepath.Join(dir, ".upgraded", "skip.sql"), []byte("X"), 0o644)
	os.WriteFile(filepath.Join(dir, ".migrate-x", "skip.sql"), []byte("X"), 0o644)
	os.WriteFile(filepath.Join(dir, "base", "real.sql"), []byte("Y"), 0o644)
	h1 := treeHash(dir)
	os.WriteFile(filepath.Join(dir, ".upgraded", "skip.sql"), []byte("ZZ"), 0o644)
	h2 := treeHash(dir)
	if h1 != h2 {
		t.Errorf("treeHash should skip .upgraded/, but changed: %s vs %s", h1, h2)
	}
}

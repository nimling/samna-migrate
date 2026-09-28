//go:build integration

package integration

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/steps"
)

func testFilesFixture(t *testing.T) (string, *steps.Config) {
	t.Helper()
	dbDir := t.TempDir()
	for _, p := range []string{
		"tests/prophet/claims.sql",
		"tests/prophet/users.sql",
		"tests/disciple/claims.sql",
		"tests/disciple/notes.txt",
		"more/extra.sql",
	} {
		full := filepath.Join(dbDir, p)
		if err := osMkdir(filepath.Dir(full)); err != nil {
			t.Fatal(err)
		}
		if err := osWrite(full, "SELECT 1;\n"); err != nil {
			t.Fatal(err)
		}
	}
	yaml := filepath.Join(dbDir, "migrate.yml")
	if err := osWrite(yaml, `name: fixture
tests:
  - tests
  - more
steps:
  - name: Base
    type: base
    slug: base
    include:
      - path: base/
`); err != nil {
		t.Fatal(err)
	}
	cfg, err := steps.Load(yaml)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return dbDir, cfg
}

func rels(t *testing.T, dbDir string, files []string) []string {
	t.Helper()
	out := make([]string, 0, len(files))
	for _, f := range files {
		rel, err := filepath.Rel(dbDir, f)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, filepath.ToSlash(rel))
	}
	return out
}

func TestTestFilesWalksEveryFolder(t *testing.T) {
	dbDir, cfg := testFilesFixture(t)
	if got := cfg.Tests; len(got) != 2 || got[0] != "tests" || got[1] != "more" {
		t.Fatalf("tests key loaded as %#v", got)
	}
	files, err := cfg.TestFiles(dbDir, "")
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(rels(t, dbDir, files), " ")
	want := "more/extra.sql tests/disciple/claims.sql tests/prophet/claims.sql tests/prophet/users.sql"
	if got != want {
		t.Fatalf("TestFiles walked %q, want %q", got, want)
	}
}

func TestTestFilesTargetFilter(t *testing.T) {
	dbDir, cfg := testFilesFixture(t)
	cases := map[string]string{
		"prophet":         "tests/prophet/claims.sql tests/prophet/users.sql",
		"claims":          "tests/disciple/claims.sql tests/prophet/claims.sql",
		"claims.sql":      "tests/disciple/claims.sql tests/prophet/claims.sql",
		"disciple/claims": "tests/disciple/claims.sql",
		"tests/prophet":   "tests/prophet/claims.sql tests/prophet/users.sql",
		"more":            "more/extra.sql",
		"prophet/notes":   "",
		"nowhere":         "",
	}
	for target, want := range cases {
		files, err := cfg.TestFiles(dbDir, target)
		if err != nil {
			t.Fatalf("%s: %v", target, err)
		}
		if got := strings.Join(rels(t, dbDir, files), " "); got != want {
			t.Errorf("target %q selected %q, want %q", target, got, want)
		}
	}
}

func TestTestDirsResolveLikeIncludes(t *testing.T) {
	dbDir, cfg := testFilesFixture(t)
	dirs := cfg.TestDirs(dbDir)
	if len(dirs) != 2 || dirs[0] != filepath.Join(dbDir, "tests") || dirs[1] != filepath.Join(dbDir, "more") {
		t.Fatalf("TestDirs = %#v", dirs)
	}
}

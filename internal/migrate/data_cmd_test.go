package migrate

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/data"
)

func TestTableFromFile(t *testing.T) {
	cases := []struct {
		path   string
		schema string
		name   string
		ok     bool
	}{
		{"/tmp/public.bookable.json", "public", "bookable", true},
		{"claimius.samna_user.json", "claimius", "samna_user", true},
		{"/tmp/notjson.txt", "", "", false},
		{"/tmp/noschema.json", "", "", false},
		{"/tmp/public.bookable.jsonl", "public", "bookable", true},
		{"/tmp/public.bookable.ndjson", "public", "bookable", true},
		{"/tmp/public.bookable.csv", "public", "bookable", true},
		{"/tmp/claimius.samna_user.sql", "claimius", "samna_user", true},
	}
	for _, c := range cases {
		tbl, ok := tableFromFile(c.path)
		if ok != c.ok || tbl.Schema != c.schema || tbl.Name != c.name {
			t.Errorf("tableFromFile(%q) = %+v %v, want {%s %s} %v", c.path, tbl, ok, c.schema, c.name, c.ok)
		}
	}
}

func TestCollectFiles(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"public.a.json", "public.b.json", "public.c.jsonl", "public.d.ndjson", "public.e.csv", "notes.txt", ".hidden.json"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("[]"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}

	files, err := collectFiles([]string{dir})
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 5 {
		t.Fatalf("collectFiles dir = %v, want 5 data files", files)
	}

	single := filepath.Join(dir, "public.a.json")
	files, err = collectFiles([]string{single, single})
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 {
		t.Errorf("collectFiles dedup = %v, want 1", files)
	}
}

func TestResolveTables(t *testing.T) {
	available := []data.Table{
		{Schema: "public", Name: "foo"},
		{Schema: "public", Name: "bar"},
		{Schema: "claimius", Name: "samna_user"},
	}
	got, err := resolveTables(available, []string{"public.foo,claimius.samna_user", "public.bar"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("resolveTables = %v, want 3", got)
	}

	if _, err := resolveTables(available, []string{"public.zzz"}); err == nil {
		t.Error("resolveTables accepted an unknown table")
	}
}

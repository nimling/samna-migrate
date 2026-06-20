package merge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCopyFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.sql")
	dst := filepath.Join(dir, "dst.sql")
	if err := os.WriteFile(src, []byte("contents"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(src, dst); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "contents" {
		t.Errorf("copy mismatch: %q", string(got))
	}
}

func TestCopyDir(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	os.MkdirAll(filepath.Join(src, "sub"), 0o755)
	os.WriteFile(filepath.Join(src, "a.sql"), []byte("A"), 0o644)
	os.WriteFile(filepath.Join(src, "sub", "b.sql"), []byte("B"), 0o644)

	if err := copyDir(src, dst); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "a.sql")); string(b) != "A" {
		t.Errorf("a.sql = %q", string(b))
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "sub", "b.sql")); string(b) != "B" {
		t.Errorf("sub/b.sql = %q", string(b))
	}
}

func TestCopyOne(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.sql")
	dst := filepath.Join(dir, "dst.sql")
	os.WriteFile(src, []byte("data"), 0o644)
	if err := copyOne(src, dst); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dst)
	if string(b) != "data" {
		t.Errorf("copyOne mismatch: %q", string(b))
	}
}

func TestFileStatementsNoSchemaObjects(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "v.sql")
	os.WriteFile(p, []byte("SELECT 1; UPDATE x SET a = 1;"), 0o644)
	got, nonSchema, err := fileStatements(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("expected no schema idents, got %v", got)
	}
	if !nonSchema {
		t.Errorf("SELECT and UPDATE must flag the file as non-schema")
	}
}

func TestHasContent(t *testing.T) {
	d := t.TempDir()
	if hasContent(d) {
		t.Error("empty dir should report no content")
	}
	os.WriteFile(filepath.Join(d, "x"), []byte("y"), 0o644)
	if !hasContent(d) {
		t.Error("dir with file should report content")
	}
}

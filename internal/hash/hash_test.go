package hash

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a.sql")
	if err := os.WriteFile(p, []byte("SELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := File(p)
	if err != nil {
		t.Fatal(err)
	}
	want := "b4e0497804e46e0a0b0b8c31975b062152d551bac49c3c2e80932567b4085dcd"
	if got != want {
		t.Errorf("sha mismatch: got %s want %s", got, want)
	}
}

func TestFileMissing(t *testing.T) {
	if _, err := File("/nonexistent/path/xyz.sql"); err == nil {
		t.Error("expected error for missing file")
	}
}

func TestSize(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "b.sql")
	if err := os.WriteFile(p, []byte("abcdef"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Size(p)
	if err != nil {
		t.Fatal(err)
	}
	if s != 6 {
		t.Errorf("size mismatch: got %d want 6", s)
	}
}

func TestFileEmpty(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "empty.sql")
	if err := os.WriteFile(p, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := File(p)
	if err != nil {
		t.Fatal(err)
	}
	// sha256 of empty input
	want := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	if got != want {
		t.Errorf("empty sha mismatch: got %s want %s", got, want)
	}
}

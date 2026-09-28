package git

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func run(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v: %s", args, err, out)
	}
}

func TestIsRepoAndFileCommit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	if IsRepo(dir) {
		t.Fatalf("fresh temp dir reported as a repo")
	}
	run(t, dir, "init", "-q")
	run(t, dir, "config", "user.email", "t@t")
	run(t, dir, "config", "user.name", "t")
	if !IsRepo(dir) {
		t.Fatalf("initialized repo not detected")
	}

	rel := "sub/a.sql"
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, rel), []byte("SELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, dir, "add", ".")
	run(t, dir, "commit", "-q", "-m", "add a")

	commit := FileCommit(dir, rel)
	if len(commit) != 40 {
		t.Fatalf("FileCommit returned %q, want a 40 char sha", commit)
	}
	if got := FileCommit(dir, "missing.sql"); got != "" {
		t.Fatalf("FileCommit for untracked file returned %q, want empty", got)
	}

	if err := os.WriteFile(filepath.Join(dir, rel), []byte("SELECT 2;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	diff := DiffSince(dir, commit, rel)
	if diff == "" {
		t.Fatalf("DiffSince returned empty for a changed file")
	}
}

func TestRootAndArchive(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	run(t, dir, "init", "-q")
	run(t, dir, "config", "user.email", "t@t")
	run(t, dir, "config", "user.name", "t")
	if err := os.MkdirAll(filepath.Join(dir, "database", "base"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "database", "base", "V1.0__app_a.sql"), []byte("SELECT 1;\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "other.txt"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, dir, "add", ".")
	run(t, dir, "commit", "-q", "-m", "add a")
	if err := os.WriteFile(filepath.Join(dir, "database", "base", "V1.0__app_a.sql"), []byte("SELECT 2;\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	root := Root(filepath.Join(dir, "database"))
	if want, _ := filepath.EvalSymlinks(dir); root != want {
		t.Fatalf("Root returned %q, want %q", root, want)
	}
	dst := t.TempDir()
	if err := Archive(dir, "HEAD", "database", dst); err != nil {
		t.Fatalf("Archive: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dst, "database", "base", "V1.0__app_a.sql"))
	if err != nil {
		t.Fatalf("archived file missing: %v", err)
	}
	if string(got) != "SELECT 1;\n" {
		t.Fatalf("archived body = %q, want the committed body", got)
	}
	if _, err := os.Stat(filepath.Join(dst, "other.txt")); err == nil {
		t.Fatalf("archive included a path outside the requested subfolder")
	}
	if err := Archive(dir, "no-such-ref", "database", t.TempDir()); err == nil {
		t.Fatalf("Archive of a missing ref did not fail")
	}
}

package steps

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestResolveFilesGitSubfolder(t *testing.T) {
	repo := t.TempDir()
	sub := filepath.Join(repo, "prophet", "database")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(sub, "V1.0__claimius_roles.sql"), []byte("-- roles"), 0o644)
	os.WriteFile(filepath.Join(sub, "V1.1__claimius_baseline.sql"), []byte("-- baseline"), 0o644)
	os.MkdirAll(filepath.Join(repo, "disciple", "database"), 0o755)
	os.WriteFile(filepath.Join(repo, "disciple", "database", "V1.0__claimius_roles.sql"), []byte("-- disciple"), 0o644)
	for _, args := range [][]string{
		{"init", "-q", "-b", "trunk"},
		{"-c", "user.email=t@t", "-c", "user.name=t", "add", "-A"},
		{"-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"},
		{"tag", "v1.0.0"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = repo
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
	}
	step := &Step{
		Name: "Claimius", Type: "base", Slug: "claimius",
		Include: []IncludeEntry{{Git: repo, Ref: "v1.0.0", Path: "prophet/database"}},
	}
	files, err := step.ResolveFiles(t.TempDir())
	if err != nil {
		t.Fatalf("ResolveFiles git: %v", err)
	}
	got := map[string]bool{}
	for _, f := range files {
		got[f.Name] = true
	}
	if len(files) != 2 || !got["V1.0__claimius_roles.sql"] || !got["V1.1__claimius_baseline.sql"] {
		t.Fatalf("git subfolder resolved %#v", files)
	}
}

func TestResolveFilesGitMissingRefFails(t *testing.T) {
	repo := t.TempDir()
	if out, err := runGit(repo, "init", "-q", "-b", "trunk"); err != nil {
		t.Fatalf("init: %v: %s", err, out)
	}
	step := &Step{
		Name: "Claimius", Type: "base", Slug: "claimius",
		Include: []IncludeEntry{{Git: repo, Ref: "v9.9.9", Path: "prophet/database"}},
	}
	if _, err := step.ResolveFiles(t.TempDir()); err == nil {
		t.Fatal("ResolveFiles must error on an unreachable git ref")
	}
}

func runGit(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	return cmd.CombinedOutput()
}

func TestParseFilename(t *testing.T) {
	cases := []struct {
		name                   string
		input                  string
		wantVer, wantSlug, wantLabel string
		wantOk                 bool
	}{
		{"v5.0 finalize", "V5.0__finalize_recompute_state.sql", "5.0", "finalize", "recompute_state", true},
		{"v1.4 base", "V1.4__base_timeslots.sql", "1.4", "base", "timeslots", true},
		{"v2.1 multi dot", "V2.1.7__claimius_calc.sql", "2.1.7", "claimius", "calc", true},
		{"missing name", "V1.0__roles.sql", "", "", "", false},
		{"zero version", "V0.0__claimius_roles.sql", "", "", "", false},
		{"no V prefix", "X1.0__foo_bar.sql", "", "", "", false},
		{"no .sql", "V1.0__foo_bar", "", "", "", false},
		{"no separator", "V1.0_foo_bar.sql", "", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			v, s, l, ok := ParseFilename(tc.input)
			if ok != tc.wantOk {
				t.Errorf("ok = %v, want %v", ok, tc.wantOk)
			}
			if v != tc.wantVer || s != tc.wantSlug || l != tc.wantLabel {
				t.Errorf("got (%q, %q, %q), want (%q, %q, %q)",
					v, s, l, tc.wantVer, tc.wantSlug, tc.wantLabel)
			}
		})
	}
}

func TestLoadAndDefaults(t *testing.T) {
	dir := t.TempDir()
	yamlPath := filepath.Join(dir, "migrate.yml")
	yaml := `
name: test
steps:
  - name: Claimius
    type: base
    slug: claimius
    schemas: [claimius]
    include:
      - path: claimius/
  - name: Migrations
    type: migration
    include:
      - path: migrations/
`
	if err := os.WriteFile(yamlPath, []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(yamlPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Steps) != 2 {
		t.Fatalf("steps = %d, want 2", len(cfg.Steps))
	}
	if cfg.Steps[0].Type != "base" {
		t.Errorf("Steps[0].Type = %q, want base", cfg.Steps[0].Type)
	}
	if cfg.Steps[1].Type != "migration" {
		t.Errorf("Steps[1].Type = %q, want migration", cfg.Steps[1].Type)
	}
	if len(cfg.Steps[0].Schemas) != 1 || cfg.Steps[0].Schemas[0] != "claimius" {
		t.Errorf("Steps[0].Schemas = %v", cfg.Steps[0].Schemas)
	}
	if len(cfg.Steps[1].Schemas) != 1 || cfg.Steps[1].Schemas[0] != "public" {
		t.Errorf("Steps[1].Schemas default = %v, want [public]", cfg.Steps[1].Schemas)
	}
	if !cfg.Slugs()["claimius"] || cfg.Slugs()["migration"] {
		t.Errorf("Slugs() = %v, want only claimius", cfg.Slugs())
	}
}

func TestLoadRejectsInvalidSteps(t *testing.T) {
	cases := []struct {
		name string
		yaml string
	}{
		{"missing type", "name: t\nsteps:\n  - name: A\n    slug: base\n    include:\n      - path: a/\n"},
		{"invalid type", "name: t\nsteps:\n  - name: A\n    type: ddl\n    slug: base\n    include:\n      - path: a/\n"},
		{"migration with slug", "name: t\nsteps:\n  - name: A\n    type: migration\n    slug: migration\n    include:\n      - path: a/\n"},
		{"base without slug", "name: t\nsteps:\n  - name: A\n    type: base\n    include:\n      - path: a/\n"},
		{"seed without slug", "name: t\nsteps:\n  - name: A\n    type: seed\n    include:\n      - path: a/\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			p := filepath.Join(dir, "migrate.yml")
			if err := os.WriteFile(p, []byte(tc.yaml), 0o644); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(p); err == nil {
				t.Errorf("Load accepted invalid config %q", tc.name)
			}
		})
	}
}

func TestResolveFiles(t *testing.T) {
	dbDir := t.TempDir()
	clmDir := filepath.Join(dbDir, "claimius")
	os.MkdirAll(clmDir, 0o755)
	for _, name := range []string{"V0.0__roles.sql", "V1.0__baseline.sql", "V5.0__finalize_recompute_state.sql", "README.md"} {
		if err := os.WriteFile(filepath.Join(clmDir, name), []byte("-- "+name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	step := &Step{
		Name: "Claimius", Type: "base", Slug: "claimius",
		Schemas: []string{"claimius"},
		Include: []IncludeEntry{{Path: "claimius/"}},
		Exclude: []IncludeEntry{{Path: "V5.0__finalize_recompute_state.sql"}},
	}
	files, err := step.ResolveFiles(dbDir)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, f := range files {
		got[f.Name] = true
	}
	if got["V5.0__finalize_recompute_state.sql"] {
		t.Error("excluded file included")
	}
	if got["README.md"] {
		t.Error("non-sql file included")
	}
	if !got["V0.0__roles.sql"] || !got["V1.0__baseline.sql"] {
		t.Errorf("missing expected files: %v", got)
	}
}

func TestResolveFilesIncludePath(t *testing.T) {
	dbDir := t.TempDir()
	clmDir := filepath.Join(dbDir, "claimius")
	os.MkdirAll(clmDir, 0o755)
	target := filepath.Join(clmDir, "V5.0__finalize_recompute_state.sql")
	os.WriteFile(target, []byte("-- single"), 0o644)

	step := &Step{
		Name: "Finalize", Type: "base", Slug: "finalize",
		Include: []IncludeEntry{{Path: "claimius/V5.0__finalize_recompute_state.sql"}},
	}
	files, err := step.ResolveFiles(dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 {
		t.Fatalf("files = %d, want 1", len(files))
	}
	if files[0].Name != "V5.0__finalize_recompute_state.sql" {
		t.Errorf("name = %q", files[0].Name)
	}
}

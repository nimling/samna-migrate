package steps

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseFilenameExtras(t *testing.T) {
	cases := []struct {
		input            string
		ver, slug, label string
		ok               bool
	}{
		{"V10.0__base_widget.sql", "10.0", "base", "widget", true},
		{"V100.5.3__migration_long.sql", "100.5.3", "migration", "long", true},
		{"V1.0__claimius2_x.sql", "1.0", "claimius2", "x", true},
		{"V1.0__system_init_disciple.sql", "1.0", "system", "init_disciple", true},
		{"V0.0__roles.sql", "0.0", "roles", "", true},
	}
	for _, tc := range cases {
		t.Run(tc.input, func(t *testing.T) {
			v, s, l, ok := ParseFilename(tc.input)
			if !ok {
				t.Fatalf("ok = false")
			}
			if v != tc.ver || s != tc.slug || l != tc.label {
				t.Errorf("got (%q, %q, %q), want (%q, %q, %q)", v, s, l, tc.ver, tc.slug, tc.label)
			}
		})
	}
}

func TestResolveFilesMultipleIncludes(t *testing.T) {
	dbDir := t.TempDir()
	a := filepath.Join(dbDir, "a")
	b := filepath.Join(dbDir, "b")
	os.MkdirAll(a, 0o755)
	os.MkdirAll(b, 0o755)
	os.WriteFile(filepath.Join(a, "V1.0__x_y.sql"), []byte("-- a"), 0o644)
	os.WriteFile(filepath.Join(b, "V2.0__x_y.sql"), []byte("-- b"), 0o644)

	step := &Step{
		Name: "Combo", Type: "seed", Slug: "combo",
		Include: []IncludeEntry{{Path: "a/"}, {Path: "b/"}},
	}
	files, err := step.ResolveFiles(dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 {
		t.Fatalf("files = %d, want 2: %#v", len(files), files)
	}
}

func TestResolveFilesFallback(t *testing.T) {
	dbDir := t.TempDir()
	// dbDir/primary does not exist; fallback inside the same tree does
	fb := filepath.Join(dbDir, "fallback")
	os.MkdirAll(fb, 0o755)
	os.WriteFile(filepath.Join(fb, "V1.0__seed_thing.sql"), []byte("-- fb"), 0o644)

	step := &Step{
		Name: "FB", Type: "seed", Slug: "fb",
		Include: []IncludeEntry{{Path: "primary/", Fallback: fb}},
	}
	files, err := step.ResolveFiles(dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 || files[0].Name != "V1.0__seed_thing.sql" {
		t.Errorf("fallback files = %#v", files)
	}
}

func TestStringIncludeNode(t *testing.T) {
	dir := t.TempDir()
	yaml := `
name: t
steps:
  - name: Plain
    type: base
    slug: plain
    include:
      - "claimius/"
`
	yp := filepath.Join(dir, "m.yml")
	os.WriteFile(yp, []byte(yaml), 0o644)
	cfg, err := Load(yp)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Steps[0].Include) != 1 || cfg.Steps[0].Include[0].Path != "claimius/" {
		t.Errorf("string include not parsed: %#v", cfg.Steps[0].Include)
	}
}

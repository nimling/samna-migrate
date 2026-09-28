//go:build e2e

package e2e

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func pgtapFixture(t *testing.T) string {
	t.Helper()
	dbDir := filepath.Join(t.TempDir(), "database")
	files := map[string]string{
		"migrate.yml": `name: fixture
tests:
  - tests
steps:
  - name: Application Tables
    type: base
    slug: app
    include:
      - path: base/
`,
		"base/V1.0__app_schema.sql": `CREATE TABLE IF NOT EXISTS public.smig_widget (id INTEGER PRIMARY KEY, qty INTEGER NOT NULL);
INSERT INTO public.smig_widget VALUES (1, 3), (2, 4) ON CONFLICT (id) DO NOTHING;
`,
		"tests/app/pass.sql": `BEGIN;
SELECT plan(2);
SELECT has_table('public', 'smig_widget', 'widget table exists');
SELECT is((SELECT sum(qty) FROM public.smig_widget)::bigint, 7::bigint, 'qty sums');
SELECT * FROM finish();
ROLLBACK;
`,
		"tests/app/fail.sql": `BEGIN;
SELECT plan(1);
SELECT is((SELECT sum(qty) FROM public.smig_widget)::bigint, 8::bigint, 'wrong on purpose');
SELECT * FROM finish();
ROLLBACK;
`,
	}
	for rel, body := range files {
		full := filepath.Join(dbDir, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dbDir
}

func TestSmigTestExitCodeContract(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not present, test needs it for the throwaway database")
	}
	dbDir := pgtapFixture(t)
	schema := "--schema=" + filepath.Join(dbDir, "migrate.yml")
	dir := "--db-dir=" + dbDir

	stdout, stderr, err := runSmig(t, "test", schema, dir)
	if err == nil {
		t.Fatalf("smig test passed with a failing file\nstdout: %s\nstderr: %s", stdout, stderr)
	}
	combined := stdout + stderr
	for _, want := range []string{"test: fresh", "ok 1 - widget table exists", "not ok 1 - wrong on purpose", "fail.sql", "1 file(s) not passing"} {
		if !strings.Contains(combined, want) {
			t.Errorf("expected %q in output: %s", want, combined)
		}
	}

	stdout, stderr, err = runSmig(t, "test", "app/pass", schema, dir)
	if err != nil {
		t.Fatalf("smig test app/pass failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	combined = stdout + stderr
	if strings.Contains(combined, "fail.sql") || !strings.Contains(combined, "test passed") {
		t.Errorf("target filter did not narrow the run: %s", combined)
	}

	stdout, stderr, err = runSmig(t, "test", "pass", "--json", schema, dir)
	if err != nil {
		t.Fatalf("smig test --json failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	if !strings.HasPrefix(strings.TrimSpace(stdout), "{") || !strings.Contains(stdout, `"plan": 2`) {
		t.Errorf("--json did not emit the parsed document: %s", stdout)
	}
}

func TestSmigTestNewWritesSkeleton(t *testing.T) {
	dbDir := pgtapFixture(t)
	schema := "--schema=" + filepath.Join(dbDir, "migrate.yml")
	dir := "--db-dir=" + dbDir

	stdout, stderr, err := runSmig(t, "test", "new", "sample", schema, dir)
	if err != nil {
		t.Fatalf("smig test new failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	body, err := os.ReadFile(filepath.Join(dbDir, "tests", "sample.sql"))
	if err != nil {
		t.Fatalf("skeleton missing: %v", err)
	}
	want := "BEGIN;\nSELECT plan(1);\nSELECT ok(true, 'sample');\nSELECT * FROM finish();\nROLLBACK;\n"
	if string(body) != want {
		t.Errorf("skeleton = %q, want %q", body, want)
	}
	if _, _, err := runSmig(t, "test", "new", "sample", schema, dir); err == nil {
		t.Errorf("smig test new overwrote an existing file")
	}
	if _, _, err := runSmig(t, "test", "new", "other", "--from=HEAD", schema, dir); err == nil {
		t.Errorf("smig test new accepted --from")
	}
}

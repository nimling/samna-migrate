package migrate

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/sqlscan"
)

func capture(f func()) string {
	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	f()
	w.Close()
	os.Stdout = old
	b, _ := io.ReadAll(r)
	return string(b)
}

const renderSample = `CREATE OR REPLACE FUNCTION app.compute(p_a UUID, p_b TEXT)
    RETURNS JSONB AS $$
DECLARE
    v1 INT;
    v2 INT;
    v3 INT;
    v4 INT;
    v5 INT;
    v6 INT;
    v7 INT;
    v8 INT;
BEGIN
    RETURN '{}'::JSONB;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE TABLE app.thing (id UUID PRIMARY KEY, name TEXT);
`

func setupSample(t *testing.T) (objColumns, map[string][]sqlscan.Object, map[string]string, string) {
	t.Helper()
	dir := t.TempDir()
	rel := "V1.0__sample.sql"
	if err := os.WriteFile(filepath.Join(dir, rel), []byte(renderSample), 0o644); err != nil {
		t.Fatal(err)
	}
	oc, byFile, content := scanObjects([]apply.Pending{{FilePath: rel, FileName: rel}}, dir)
	return oc, byFile, content, rel
}

func TestLogObjectsSilentAndNormal(t *testing.T) {
	oc, byFile, content, rel := setupSample(t)
	defer func() { log.Level = log.LevelNormal }()

	for _, lvl := range []int{log.LevelNormal, log.LevelSilent} {
		log.Level = lvl
		h := false
		out := capture(func() { logObjects(oc, byFile[rel], content[rel], rel, &h) })
		if out != "" {
			t.Errorf("level %d printed object table: %q", lvl, out)
		}
	}
}

func TestLogObjectsVerbosePreview(t *testing.T) {
	oc, byFile, content, rel := setupSample(t)
	defer func() { log.Level = log.LevelNormal }()

	log.Level = log.LevelVerbose
	h := false
	out := capture(func() { logObjects(oc, byFile[rel], content[rel], rel, &h) })

	for _, want := range []string{"function", "app.compute", "params", "CREATE OR REPLACE FUNCTION", "more lines"} {
		if !strings.Contains(out, want) {
			t.Errorf("verbose output missing %q\n%s", want, out)
		}
	}
	if strings.Contains(out, "──") {
		t.Errorf("verbose output should not contain the full file dump marker\n%s", out)
	}
}

func TestLogObjectsHeaderOncePerStep(t *testing.T) {
	oc, byFile, content, rel := setupSample(t)
	defer func() { log.Level = log.LevelNormal }()

	log.Level = log.LevelVerbose
	h := false
	out := capture(func() {
		logObjects(oc, byFile[rel], content[rel], rel, &h)
		logObjects(oc, byFile[rel], content[rel], rel, &h)
	})
	if n := strings.Count(out, "params"); n != 1 {
		t.Errorf("header printed %d times across two files, want 1\n%s", n, out)
	}
}

func TestLogObjectsExtremeDump(t *testing.T) {
	oc, byFile, content, rel := setupSample(t)
	defer func() { log.Level = log.LevelNormal }()

	log.Level = log.LevelExtreme
	h := false
	out := capture(func() { logObjects(oc, byFile[rel], content[rel], rel, &h) })

	if !strings.Contains(out, "──") {
		t.Errorf("extreme output missing full file dump marker\n%s", out)
	}
	if !strings.Contains(out, "RETURN '{}'::JSONB;") {
		t.Errorf("extreme output missing raw file body line\n%s", out)
	}
}

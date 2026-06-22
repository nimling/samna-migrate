package migrate

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/log"
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

func writeSample(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "V1.0__sample.sql")
	if err := os.WriteFile(path, []byte(renderSample), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLogObjectsSilentAndNormal(t *testing.T) {
	path := writeSample(t)
	defer func() { log.Level = log.LevelNormal }()

	log.Level = log.LevelNormal
	if out := capture(func() { logObjects(path) }); out != "" {
		t.Errorf("normal level printed object table: %q", out)
	}
	log.Level = log.LevelSilent
	if out := capture(func() { logObjects(path) }); out != "" {
		t.Errorf("silent level printed object table: %q", out)
	}
}

func TestLogObjectsVerbosePreview(t *testing.T) {
	path := writeSample(t)
	defer func() { log.Level = log.LevelNormal }()

	log.Level = log.LevelVerbose
	out := capture(func() { logObjects(path) })

	for _, want := range []string{"function", "app.compute", "params", "CREATE OR REPLACE FUNCTION", "more lines"} {
		if !strings.Contains(out, want) {
			t.Errorf("verbose output missing %q\n%s", want, out)
		}
	}
	if strings.Contains(out, "──") {
		t.Errorf("verbose output should not contain the full file dump marker\n%s", out)
	}
}

func TestLogObjectsExtremeDump(t *testing.T) {
	path := writeSample(t)
	defer func() { log.Level = log.LevelNormal }()

	log.Level = log.LevelExtreme
	out := capture(func() { logObjects(path) })

	if !strings.Contains(out, "──") {
		t.Errorf("extreme output missing full file dump marker\n%s", out)
	}
	if !strings.Contains(out, "RETURN '{}'::JSONB;") {
		t.Errorf("extreme output missing raw file body line\n%s", out)
	}
}

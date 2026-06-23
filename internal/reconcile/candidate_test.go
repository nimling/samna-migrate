package reconcile

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/steps"
)

func TestMaterializeCandidateOverlay(t *testing.T) {
	dbDir := t.TempDir()
	baseDir := filepath.Join(dbDir, "claimius")
	migDir := filepath.Join(dbDir, "migrations")
	os.MkdirAll(baseDir, 0o755)
	os.MkdirAll(migDir, 0o755)
	stepsFile := filepath.Join(dbDir, "migrate.yml")
	os.WriteFile(stepsFile, []byte("name: t\nsteps: []\n"), 0o644)
	os.WriteFile(filepath.Join(baseDir, "V1.0__baseline.sql"), []byte("CREATE TABLE public.a (id INT);"), 0o644)
	os.WriteFile(filepath.Join(baseDir, "V2.0__functions.sql"), []byte("SELECT 1;"), 0o644)
	os.WriteFile(filepath.Join(migDir, "V5.0__folded.sql"), []byte("ALTER TABLE public.a ADD COLUMN n INT;"), 0o644)
	os.WriteFile(filepath.Join(migDir, "V6.0__review.sql"), []byte("UPDATE public.a SET n = 1;"), 0o644)

	upgradedDir := filepath.Join(dbDir, ".upgraded")
	os.MkdirAll(filepath.Join(upgradedDir, "claimius"), 0o755)
	os.MkdirAll(filepath.Join(upgradedDir, "migrations"), 0o755)
	os.WriteFile(filepath.Join(upgradedDir, "claimius", "V2.0__functions.sql"), []byte("SELECT 2;"), 0o644)
	os.WriteFile(filepath.Join(upgradedDir, "migrations", "V5.0__folded.sql"), []byte{}, 0o644)
	os.WriteFile(filepath.Join(upgradedDir, "migrations", "V6.0__review.sql"), []byte("UPDATE public.a SET n = 1;"), 0o644)

	cfg := &steps.Config{Steps: []steps.Step{
		{Name: "Claimius", Type: "base", Slug: "claimius", Include: []steps.IncludeEntry{{Path: "claimius/"}}},
		{Name: "Migrations", Type: "migration", Slug: "migration", Include: []steps.IncludeEntry{{Path: "migrations/"}}},
	}}

	candidateDir, candSteps, err := materializeCandidate(cfg, stepsFile, dbDir, upgradedDir)
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(candidateDir)

	if _, err := os.Stat(candSteps); err != nil {
		t.Errorf("steps file missing in candidate: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(candidateDir, "claimius", "V1.0__baseline.sql"))
	if err != nil || string(b) != "CREATE TABLE public.a (id INT);" {
		t.Errorf("untouched file not copied verbatim: %q err=%v", b, err)
	}
	b, err = os.ReadFile(filepath.Join(candidateDir, "claimius", "V2.0__functions.sql"))
	if err != nil || string(b) != "SELECT 2;" {
		t.Errorf("overlay content not used: %q err=%v", b, err)
	}
	if _, err := os.Stat(filepath.Join(candidateDir, "migrations", "V5.0__folded.sql")); !os.IsNotExist(err) {
		t.Errorf("folded migration should be absent from candidate")
	}
	b, err = os.ReadFile(filepath.Join(candidateDir, "migrations", "V6.0__review.sql"))
	if err != nil || string(b) != "UPDATE public.a SET n = 1;" {
		t.Errorf("review migration not carried: %q err=%v", b, err)
	}
}

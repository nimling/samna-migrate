package verify

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTreeShaStableAndSensitive(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "claimius"), 0o755)
	os.MkdirAll(filepath.Join(dir, "migrations"), 0o755)
	os.WriteFile(filepath.Join(dir, "claimius", "a.sql"), []byte("SELECT 1;"), 0o644)
	os.WriteFile(filepath.Join(dir, "migrations", "b.sql"), []byte{}, 0o644)

	h1, err := TreeSha(dir)
	if err != nil {
		t.Fatal(err)
	}
	h2, _ := TreeSha(dir)
	if h1 != h2 {
		t.Errorf("TreeSha not deterministic: %s vs %s", h1, h2)
	}

	os.WriteFile(filepath.Join(dir, "verify.json"), []byte(`{"x":1}`), 0o644)
	h3, _ := TreeSha(dir)
	if h3 != h1 {
		t.Errorf("TreeSha must ignore the manifest file")
	}

	os.WriteFile(filepath.Join(dir, "migrations", "b.sql"), []byte("X"), 0o644)
	h4, _ := TreeSha(dir)
	if h4 == h1 {
		t.Errorf("TreeSha must change when an empty placeholder gains content")
	}
}

func TestManifestRoundtrip(t *testing.T) {
	dir := t.TempDir()
	m := &Manifest{
		UpgradedSha:    "abc",
		VerifiedAt:     "2026-06-12T00:00:00Z",
		ToolVersion:    "dev",
		SourceDatabase: "bookable",
		Image:          "postgres:17",
		Verdicts:       Verdicts{Bootstrap: true, Equality: true, Reapply: false},
	}
	if err := WriteManifest(dir, m); err != nil {
		t.Fatal(err)
	}
	got, err := ReadManifest(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got.UpgradedSha != "abc" || got.SourceDatabase != "bookable" {
		t.Errorf("roundtrip mismatch: %+v", got)
	}
	if got.AllPassed() {
		t.Errorf("AllPassed must be false when a verdict failed")
	}
	got.Verdicts.Reapply = true
	if !got.AllPassed() {
		t.Errorf("AllPassed must be true when every verdict passed")
	}
}

func TestCompareInventories(t *testing.T) {
	live := map[string]string{"a": "1", "b": "2", "c": "3"}
	cand := map[string]string{"a": "1", "b": "9", "d": "4"}
	diff := CompareInventories(live, cand)
	if len(diff.Missing) != 1 || diff.Missing[0] != "c" {
		t.Errorf("missing wrong: %v", diff.Missing)
	}
	if len(diff.Extra) != 1 || diff.Extra[0] != "d" {
		t.Errorf("extra wrong: %v", diff.Extra)
	}
	if len(diff.Different) != 1 || diff.Different[0] != "b" {
		t.Errorf("different wrong: %v", diff.Different)
	}
	if diff.Empty() {
		t.Errorf("diff must not be empty")
	}
	same := CompareInventories(live, live)
	if !same.Empty() {
		t.Errorf("identical inventories must be empty diff")
	}
}

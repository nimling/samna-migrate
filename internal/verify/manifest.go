package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const manifestName = "verify.json"

type Verdicts struct {
	Bootstrap   bool `json:"bootstrap"`
	Equality    bool `json:"equality"`
	Determinism bool `json:"determinism"`
}

type Manifest struct {
	UpgradedSha    string   `json:"upgraded_sha"`
	VerifiedAt     string   `json:"verified_at"`
	ToolVersion    string   `json:"tool_version"`
	SourceDatabase string   `json:"source_database"`
	Image          string   `json:"image"`
	Verdicts       Verdicts `json:"verdicts"`
}

func (m *Manifest) AllPassed() bool {
	return m.Verdicts.Bootstrap && m.Verdicts.Equality && m.Verdicts.Determinism
}

func TreeSha(upgradedDir string) (string, error) {
	var rels []string
	err := filepath.Walk(upgradedDir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(p, ".sql") {
			return err
		}
		rel, _ := filepath.Rel(upgradedDir, p)
		rels = append(rels, rel)
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(rels)
	hasher := sha256.New()
	for _, rel := range rels {
		hasher.Write([]byte(rel))
		hasher.Write([]byte{0})
		b, err := os.ReadFile(filepath.Join(upgradedDir, rel))
		if err != nil {
			return "", err
		}
		hasher.Write(b)
		hasher.Write([]byte{0})
	}
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func WriteManifest(upgradedDir string, m *Manifest) error {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(upgradedDir, manifestName), append(b, '\n'), 0o644)
}

func ReadManifest(upgradedDir string) (*Manifest, error) {
	b, err := os.ReadFile(filepath.Join(upgradedDir, manifestName))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return &m, nil
}

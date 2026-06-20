package verify

import (
	"io"
	"os"
	"path/filepath"

	"github.com/nimling/samna-migrate/internal/steps"
)

func materializeCandidate(stepsCfg *steps.Config, stepsFile, dbDir, upgradedDir string) (string, string, error) {
	candidateDir, err := os.MkdirTemp("", "smig-verify-")
	if err != nil {
		return "", "", err
	}
	stepsName := filepath.Base(stepsFile)
	if err := copyFile(stepsFile, filepath.Join(candidateDir, stepsName)); err != nil {
		os.RemoveAll(candidateDir)
		return "", "", err
	}
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			os.RemoveAll(candidateDir)
			return "", "", err
		}
		for _, f := range files {
			folder := f.Folder
			if st.Type == "migration" {
				folder = "migrations"
			}
			src := f.AbsPath
			if upgradedDir != "" {
				overlay := filepath.Join(upgradedDir, folder, f.Name)
				if info, err := os.Stat(overlay); err == nil {
					if info.Size() == 0 {
						continue
					}
					src = overlay
				}
			}
			dest := filepath.Join(candidateDir, f.Rel)
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				os.RemoveAll(candidateDir)
				return "", "", err
			}
			if err := copyFile(src, dest); err != nil {
				os.RemoveAll(candidateDir)
				return "", "", err
			}
		}
	}

	// Copy files the merge created that have no source counterpart, the new
	// concept and deferred default files, into their folder under the
	// candidate. The dropped review folder and migration placeholders stay out.
	if upgradedDir != "" {
		err = filepath.Walk(upgradedDir, func(p string, info os.FileInfo, werr error) error {
			if werr != nil || info.IsDir() || filepath.Ext(p) != ".sql" || info.Size() == 0 {
				return werr
			}
			rel, _ := filepath.Rel(upgradedDir, p)
			top := rel[:len(rel)-len(filepath.Base(rel))]
			if top == "migrations/" || top == "dropped/" {
				return nil
			}
			dest := filepath.Join(candidateDir, rel)
			if _, err := os.Stat(dest); err == nil {
				return nil
			}
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				return err
			}
			return copyFile(p, dest)
		})
		if err != nil {
			os.RemoveAll(candidateDir)
			return "", "", err
		}
	}
	return candidateDir, filepath.Join(candidateDir, stepsName), nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func hasContent(p string) bool {
	entries, err := os.ReadDir(p)
	return err == nil && len(entries) > 0
}

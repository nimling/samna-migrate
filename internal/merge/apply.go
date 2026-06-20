package merge

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/verify"
)

func Apply(ctx context.Context, d *db.DB, cfg *config.Config, stepsCfg *steps.Config, dbDir, toolVersion string, tag, force bool) error {
	upgradedDir := filepath.Join(filepath.Dir(cfg.StepsFile), ".upgraded")
	if !hasContent(upgradedDir) {
		return fmt.Errorf(".upgraded/ is missing or empty")
	}

	if !force {
		m, err := verify.ReadManifest(upgradedDir)
		if err != nil {
			return fmt.Errorf(".upgraded/ carries no verify proof. Run smig verify first or pass --force")
		}
		sha, err := verify.TreeSha(upgradedDir)
		if err != nil {
			return err
		}
		if m.UpgradedSha != sha {
			return fmt.Errorf("verify proof is stale, .upgraded/ changed after the last smig verify. Rerun smig verify or pass --force")
		}
		if !m.AllPassed() {
			return fmt.Errorf("verify proof records a failed verdict. Fix the tree, rerun smig verify, or pass --force")
		}
		log.Success("verify proof accepted, verified at %s against %s", m.VerifiedAt, m.SourceDatabase)
	}

	sourceRoot := filepath.Dir(cfg.StepsFile)
	ts := time.Now().UTC().Format("20060102T150405Z")
	treeSha := treeHash(sourceRoot)
	snapDir := filepath.Join(sourceRoot, fmt.Sprintf(".migrate-%s-%s", ts, treeSha))

	if tag {
		if _, err := exec.LookPath("git"); err != nil {
			return fmt.Errorf("git not found, cannot create tag")
		}
		out, err := exec.Command("git", "-C", sourceRoot, "rev-parse", "--git-dir").Output()
		if err != nil || strings.TrimSpace(string(out)) == "" {
			return fmt.Errorf("source tree is not inside a git repository")
		}
		out, _ = exec.Command("git", "-C", sourceRoot, "status", "--porcelain").Output()
		if strings.TrimSpace(string(out)) != "" {
			return fmt.Errorf("git working tree is not clean, refusing to tag")
		}
	}

	log.Header("snapshot source tree")
	if err := os.MkdirAll(snapDir, 0o755); err != nil {
		return err
	}
	for _, st := range stepsCfg.Steps {
		files, _ := st.ResolveFiles(dbDir)
		seenFolders := map[string]bool{}
		for _, f := range files {
			if seenFolders[f.Folder] {
				continue
			}
			seenFolders[f.Folder] = true
			folderAbs := filepath.Dir(f.AbsPath)
			dest := filepath.Join(snapDir, f.Folder)
			if err := copyDir(folderAbs, dest); err != nil {
				return fmt.Errorf("snapshot %s: %w", f.Folder, err)
			}
		}
	}
	log.Success("snapshot at %s", snapDir)

	if tag {
		tagName := fmt.Sprintf("migrate-apply-%s-%s", ts, treeSha)
		exec.Command("git", "-C", sourceRoot, "tag", "-a", tagName, "-m", "snapshot "+snapDir).Run()
		log.Success("git tag %s", tagName)
	}

	log.Header("move .upgraded/ into source tree")
	totalMoved := 0
	err := filepath.Walk(upgradedDir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(p, ".sql") {
			return err
		}
		rel, _ := filepath.Rel(upgradedDir, p)
		dest := filepath.Join(sourceRoot, rel)
		os.MkdirAll(filepath.Dir(dest), 0o755)
		info, _ = os.Stat(p)
		if info.Size() == 0 {
			if _, err := os.Stat(dest); err == nil {
				os.Remove(dest)
				log.Plain("  - removed %s (folded)", rel)
			}
			return nil
		}
		if err := os.Rename(p, dest); err != nil {
			return err
		}
		log.Plain("  + %s", rel)
		totalMoved++
		return nil
	})
	if err != nil {
		return err
	}
	os.RemoveAll(upgradedDir)
	log.Success("removed .upgraded/")

	log.Header("reconcile samna_migrate.file")
	disk := diskPaths(stepsCfg, dbDir)
	folded, rekeyed := 0, 0

	rows, _ := d.Pool.Query(ctx, `SELECT id, file_path, step_type FROM samna_migrate.file WHERE state = 'applied'`)
	type appliedRow struct {
		ID       int
		FilePath string
		StepType string
	}
	var appliedRows []appliedRow
	for rows.Next() {
		var r appliedRow
		rows.Scan(&r.ID, &r.FilePath, &r.StepType)
		appliedRows = append(appliedRows, r)
	}
	rows.Close()
	for _, r := range appliedRows {
		if !disk[r.FilePath] {
			if r.StepType == "migration" {
				d.Pool.Exec(ctx, `UPDATE samna_migrate.file SET state = 'folded', folded_at = NOW() WHERE id = $1`, r.ID)
				folded++
				log.Plain("  o folded %s", r.FilePath)
			} else {
				d.Pool.Exec(ctx, `UPDATE samna_migrate.file SET removed_at = NOW() WHERE id = $1`, r.ID)
			}
		}
	}

	for _, st := range stepsCfg.Steps {
		files, _ := st.ResolveFiles(dbDir)
		for _, f := range files {
			sha, _ := hash.File(f.AbsPath)
			size, _ := hash.Size(f.AbsPath)
			var exists int
			d.Pool.QueryRow(ctx, `SELECT 1 FROM samna_migrate.file WHERE file_path = $1`, f.Rel).Scan(&exists)
			if exists == 0 {
				ver, slug, _, _ := steps.ParseFilename(f.Name)
				if slug == "" {
					slug = st.Slug
				}
				d.Pool.Exec(ctx, `
					INSERT INTO samna_migrate.file (step_name, step_type, slug, version, file_name, file_path,
					                                 sha256, size_bytes, state, position)
					VALUES ($1, $2, $3, NULLIF($4, ''), $5, $6, $7, $8, 'applied',
					        COALESCE((SELECT MAX(position) FROM samna_migrate.file), 0) + 1)`,
					st.Name, st.Type, slug, ver, f.Name, f.Rel, sha, size)
				rekeyed++
			} else {
				if err := d.ExecUpgrade(ctx, `UPDATE samna_migrate.file SET sha256 = $1, size_bytes = $2, updated_at = now() WHERE file_path = $3`,
					sha, size, f.Rel); err != nil {
					log.Warn("rekey %s: %v", f.Rel, err)
				}
			}
		}
	}

	notes := fmt.Sprintf("moved=%d folded=%d rekeyed=%d", totalMoved, folded, rekeyed)
	d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.history (step_name, file_path, action_type, tool_version,
		                                    executed_by, host, database, duration_ms, success,
		                                    started_at, ended_at, notes)
		VALUES ('apply', $1, 'merge_apply', $2, $3, $4, $5, 0, true, now(), now(), $6)`,
		snapDir, toolVersion, cfg.PGUser, hostOrLocal(cfg), cfg.PGDatabase, notes)

	refreshed, err := lock.RefreshIfPresent(ctx, d, dbDir, cfg.PGDatabase, toolVersion)
	if err != nil {
		log.Warn("lockfile refresh: %v", err)
	} else if refreshed {
		log.Info("refreshed %s", lock.Path(dbDir))
	}

	log.Success("apply complete  moved=%d folded=%d rekeyed=%d", totalMoved, folded, rekeyed)
	log.Plain("snapshot retained at %s", snapDir)
	return nil
}

func diskPaths(stepsCfg *steps.Config, dbDir string) map[string]bool {
	out := map[string]bool{}
	for _, st := range stepsCfg.Steps {
		files, _ := st.ResolveFiles(dbDir)
		for _, f := range files {
			out[f.Rel] = true
		}
	}
	return out
}

func treeHash(root string) string {
	hasher := sha256.New()
	var files []string
	filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		if !strings.HasSuffix(p, ".sql") {
			return nil
		}
		if strings.Contains(p, "/.upgraded/") || strings.Contains(p, "/.migrate-") {
			return nil
		}
		files = append(files, p)
		return nil
	})
	sort.Strings(files)
	for _, p := range files {
		if b, err := os.ReadFile(p); err == nil {
			hasher.Write(b)
		}
	}
	return hex.EncodeToString(hasher.Sum(nil))[:8]
}

func copyDir(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(target)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	})
}

func hostOrLocal(c *config.Config) string {
	if c.PGHost == "" {
		return "localhost"
	}
	return c.PGHost
}

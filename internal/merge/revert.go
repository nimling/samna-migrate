package merge

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/steps"
)

func Revert(ctx context.Context, d *db.DB, cfg *config.Config, stepsCfg *steps.Config, dbDir, toolVersion, target string, force bool) error {
	sourceRoot := filepath.Dir(cfg.StepsFile)
	snapDir := ""

	if target != "" {
		snapDir = filepath.Join(sourceRoot, ".migrate-"+strings.TrimPrefix(target, ".migrate-"))
		if _, err := os.Stat(snapDir); err != nil {
			snapDir = ""
		}
	}
	if snapDir == "" {
		entries, err := os.ReadDir(sourceRoot)
		if err != nil {
			return err
		}
		var candidates []os.DirEntry
		for _, e := range entries {
			if e.IsDir() && strings.HasPrefix(e.Name(), ".migrate-") {
				candidates = append(candidates, e)
			}
		}
		if len(candidates) == 0 {
			return fmt.Errorf("no snapshot found")
		}
		sort.Slice(candidates, func(i, j int) bool {
			ai, _ := candidates[i].Info()
			aj, _ := candidates[j].Info()
			return ai.ModTime().After(aj.ModTime())
		})
		snapDir = filepath.Join(sourceRoot, candidates[0].Name())
	}

	var lastAction string
	d.Pool.QueryRow(ctx, `
		SELECT action_type FROM samna_migrate.history
		WHERE action_type IN ('merge_apply','merge_revert')
		ORDER BY id DESC LIMIT 1`).Scan(&lastAction)
	if lastAction != "merge_apply" && !force {
		return fmt.Errorf("most recent merge action is not merge_apply; revert requires --force")
	}

	ts := time.Now().UTC().Format("20060102T150405Z")
	treeSha := treeHashRevert(sourceRoot)
	preRevertSnap := filepath.Join(sourceRoot, fmt.Sprintf(".migrate-%s-%s", ts, treeSha))

	log.Header("snapshot current tree before revert")
	os.MkdirAll(preRevertSnap, 0o755)
	for _, st := range stepsCfg.Steps {
		files, _ := st.ResolveFiles(dbDir)
		seenFolders := map[string]bool{}
		for _, f := range files {
			if seenFolders[f.Folder] {
				continue
			}
			seenFolders[f.Folder] = true
			folderAbs := filepath.Dir(f.AbsPath)
			dest := filepath.Join(preRevertSnap, f.Folder)
			copyDir(folderAbs, dest)
		}
	}
	log.Success("pre revert snapshot at %s", preRevertSnap)

	log.Header("restore from " + snapDir)
	restored := 0
	err := filepath.Walk(snapDir, func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(p, ".sql") {
			return nil
		}
		rel, _ := filepath.Rel(snapDir, p)
		dest := filepath.Join(sourceRoot, rel)
		os.MkdirAll(filepath.Dir(dest), 0o755)
		if err := copyOne(p, dest); err != nil {
			return err
		}
		log.Plain("  + %s", rel)
		restored++
		return nil
	})
	if err != nil {
		return err
	}

	log.Header("reconcile samna_migrate.file")
	d.Pool.Exec(ctx, `
		UPDATE samna_migrate.file
		SET state = 'applied', folded_at = NULL
		WHERE state = 'folded'
		  AND folded_at > (
		      SELECT applied_at FROM samna_migrate.history
		      WHERE action_type = 'merge_apply'
		      ORDER BY id DESC LIMIT 1)`)

	notes := fmt.Sprintf("restored=%d pre_revert_snapshot=%s", restored, preRevertSnap)
	d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.history (step_name, file_path, action_type, tool_version,
		                                    executed_by, host, database, duration_ms, success,
		                                    started_at, ended_at, notes)
		VALUES ('revert', $1, 'merge_revert', $2, $3, $4, $5, 0, true, now(), now(), $6)`,
		snapDir, toolVersion, cfg.PGUser, hostOrLocal(cfg), cfg.PGDatabase, notes)

	log.Success("revert complete  restored=%d", restored)
	log.Plain("pre revert snapshot retained at %s", preRevertSnap)
	return nil
}

func treeHashRevert(root string) string {
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

func copyOne(src, dst string) error {
	in, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, in, 0o644)
}

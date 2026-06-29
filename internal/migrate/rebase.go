package migrate

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/git"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	rebaseReason string
	rebaseUndo   bool
	rebaseUndoID int
	rebasePrune  bool
)

var rebaseCmd = &cobra.Command{
	Use:   "rebase [file_path]...",
	Short: "Mirror the local file structure into samna_migrate as the deployed truth, reversibly",
	Long: `rebase accepts the on disk content of files as the deployed truth and writes
both the checksum and the body into samna_migrate. With no arguments it mirrors
the whole local tree; with file_path arguments it mirrors only those files.

Every mirror first snapshots the prior body into a history row with action_type
rebase, so the change is reversible. --undo restores the most recent snapshot for
each target file; --undo-id <history_id> restores one specific snapshot. The diff
between the prior body and the new body is shown as a git style diff under -v.

--prune folds every applied migration entry that is absent from the source tree,
the state a history squash leaves behind, so up stops refusing on a file the
ledger applied but the tree no longer carries. It folds only orphaned migration
entries and never touches pending files. Run reconcile --db first to confirm the
folded migrations' objects are still produced by the tree.

Refreshes ` + lock.FileName + ` when it exists.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			if err := config.LoadDotEnv(envFile); err != nil {
				return err
			}
		}
		cfg := config.FromEnv()
		cfg.StepsFile = stepsFile
		cfg.DBDir = dbDir
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		if err := bootCheck(ctx, d, stepsFile, dbDir, cli.Version); err != nil {
			return err
		}

		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}

		if rebasePrune {
			return runRebasePrune(ctx, d, cfg, stepsCfg)
		}

		targets, err := rebaseTargets(args, stepsCfg)
		if err != nil {
			return err
		}

		if rebaseUndo || rebaseUndoID != 0 {
			return runRebaseUndo(ctx, d, cfg, targets)
		}

		if err := confirmRebase(cfg, targets); err != nil {
			return err
		}
		return runRebaseMirror(ctx, d, cfg, stepsCfg, targets)
	},
}

func rebaseTargets(args []string, stepsCfg *steps.Config) ([]string, error) {
	if len(args) > 0 {
		return args, nil
	}
	var rels []string
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			rels = append(rels, f.Rel)
		}
	}
	return rels, nil
}

func runRebaseMirror(ctx context.Context, d *db.DB, cfg *config.Config, stepsCfg *steps.Config, targets []string) error {
	host := hostOrLocalhost(cfg)
	log.Header(fmt.Sprintf("rebase: mirror %d file(s) into %s", len(targets), cfg.PGDatabase))

	rightEdge := 0
	for _, fp := range targets {
		if w := 4 + len(fp) + 2 + len("registered"); w > rightEdge {
			rightEdge = w
		}
	}

	mirrored := 0
	for _, fp := range targets {
		abs := dbDir + "/" + fp
		diskSha, err := hash.File(abs)
		if err != nil {
			return fmt.Errorf("read %s: %w", fp, err)
		}
		size, _ := hash.Size(abs)
		raw, err := os.ReadFile(abs)
		if err != nil {
			return fmt.Errorf("read %s: %w", fp, err)
		}
		content := string(raw)
		commit := git.FileCommit(dbDir, fp)

		var id, priorSize int
		var dbSha, state string
		var priorAppliedSha, priorContent *string
		var appliedAt *time.Time
		err = d.Pool.QueryRow(ctx, `
			SELECT id, sha256, COALESCE(applied_sha256, ''), applied_sql, size_bytes, state, applied_at
			FROM samna_migrate.file WHERE file_path = $1`, fp).
			Scan(&id, &dbSha, &priorAppliedSha, &priorContent, &priorSize, &state, &appliedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			if err := registerRebaseFile(ctx, d, cfg, stepsCfg, fp, diskSha, size, content, commit, host, rightEdge); err != nil {
				return err
			}
			mirrored++
			continue
		}
		if err != nil {
			return fmt.Errorf("%s lookup failed: %w", fp, err)
		}

		priorSha := dbSha
		if s := strings.TrimSpace(derefStr(priorAppliedSha)); s != "" {
			priorSha = s
		}
		if priorSha == diskSha && state == "applied" {
			log.Detail("  %s already mirrored, skipping", fp)
			continue
		}

		notes := fmt.Sprintf("prior=%s new=%s reason=%s", priorSha, diskSha, rebaseReason)
		_, err = d.Pool.Exec(ctx, `
			INSERT INTO samna_migrate.history (file_id, step_name, file_path, file_name, sha256, size_bytes,
			                                    applied_sql, applied_commit, action_type, tool_version, executed_by, host, database,
			                                    duration_ms, success, started_at, ended_at, notes)
			VALUES ($1, 'rebase', $2, $3, $4, $5, $6, NULLIF($7, ''), 'rebase', $8, $9, $10, $11, 0, true, now(), now(), $12)`,
			id, fp, baseName(fp), priorSha, priorSize, priorContent, commit, cli.Version, cfg.PGUser, host, cfg.PGDatabase, notes)
		if err != nil {
			return err
		}

		if err := d.ExecUpgrade(ctx, `
			UPDATE samna_migrate.file SET
			    sha256           = $1,
			    applied_sha256   = $1,
			    applied_sql      = $2,
			    applied_commit   = NULLIF($3, ''),
			    size_bytes       = $4,
			    state            = CASE WHEN state = 'pending' AND applied_at IS NOT NULL THEN 'applied' ELSE state END,
			    state_changed_at = now(),
			    updated_at       = now()
			WHERE id = $5`, diskSha, content, commit, size, id); err != nil {
			return err
		}

		log.Step(fp, "mirrored", rightEdge)
		log.Detail("      %s to %s", shortSha(priorSha), shortSha(diskSha))
		if log.Level == log.LevelVerbose {
			reconcile.PrintDiff(derefStr(priorContent), content)
		}
		mirrored++
	}

	log.Plain("")
	log.Success("mirrored %d file(s)", mirrored)
	return refreshLock(ctx, d, cfg)
}

func registerRebaseFile(ctx context.Context, d *db.DB, cfg *config.Config, stepsCfg *steps.Config, fp, diskSha string, size int64, content, commit, host string, rightEdge int) error {
	st, err := apply.FileRel(stepsCfg, fp, dbDir)
	if err != nil {
		return err
	}
	ver, slug, _, _ := steps.ParseFilename(baseName(fp))
	if slug == "" {
		slug = st.Slug
	}

	var id int
	err = d.Pool.QueryRow(ctx, `
		INSERT INTO samna_migrate.file
		    (step_name, step_type, slug, version, file_name, file_path, sha256, applied_sha256,
		     applied_sql, applied_commit, size_bytes, state, position, applied_position, applied_at,
		     first_seen, discovered_at, state_changed_at, updated_at)
		VALUES ($1, $2, $3, NULLIF($4, ''), $5, $6, $7, $7, $8, NULLIF($10, ''), $9, 'applied',
		        COALESCE((SELECT MAX(position) FROM samna_migrate.file), 0) + 1,
		        COALESCE((SELECT MAX(position) FROM samna_migrate.file), 0) + 1,
		        now(), now(), now(), now(), now())
		RETURNING id`,
		st.Name, st.Type, slug, ver, baseName(fp), fp, diskSha, content, size, commit).Scan(&id)
	if err != nil {
		return fmt.Errorf("register %s: %w", fp, err)
	}

	notes := fmt.Sprintf("registered new=%s reason=%s", diskSha, rebaseReason)
	_, err = d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.history (file_id, step_name, file_path, file_name, sha256, size_bytes,
		                                    applied_sql, applied_commit, action_type, tool_version, executed_by, host, database,
		                                    duration_ms, success, started_at, ended_at, notes)
		VALUES ($1, 'rebase', $2, $3, $4, $5, $6, NULLIF($7, ''), 'rebase', $8, $9, $10, $11, 0, true, now(), now(), $12)`,
		id, fp, baseName(fp), diskSha, size, content, commit, cli.Version, cfg.PGUser, host, cfg.PGDatabase, notes)
	if err != nil {
		return err
	}

	log.Step(fp, "registered", rightEdge)
	log.Detail("      %s", shortSha(diskSha))
	return nil
}

func runRebaseUndo(ctx context.Context, d *db.DB, cfg *config.Config, targets []string) error {
	host := hostOrLocalhost(cfg)
	log.Header(fmt.Sprintf("rebase undo: %s", cfg.PGDatabase))

	type snapshot struct {
		histID   int
		fileID   int
		filePath string
		sha      string
		content  *string
		size     int
	}
	var snaps []snapshot

	if rebaseUndoID != 0 {
		var s snapshot
		err := d.Pool.QueryRow(ctx, `
			SELECT id, file_id, file_path, sha256, applied_sql, COALESCE(size_bytes, 0)
			FROM samna_migrate.history
			WHERE id = $1 AND action_type = 'rebase'`, rebaseUndoID).
			Scan(&s.histID, &s.fileID, &s.filePath, &s.sha, &s.content, &s.size)
		if err != nil {
			return fmt.Errorf("no rebase snapshot with id %d: %w", rebaseUndoID, err)
		}
		snaps = append(snaps, s)
	} else {
		for _, fp := range targets {
			var s snapshot
			err := d.Pool.QueryRow(ctx, `
				SELECT id, file_id, file_path, sha256, applied_sql, COALESCE(size_bytes, 0)
				FROM samna_migrate.history
				WHERE file_path = $1 AND action_type = 'rebase'
				ORDER BY id DESC LIMIT 1`, fp).
				Scan(&s.histID, &s.fileID, &s.filePath, &s.sha, &s.content, &s.size)
			if err != nil {
				log.Detail("  %s has no rebase snapshot, skipping", fp)
				continue
			}
			snaps = append(snaps, s)
		}
	}

	if len(snaps) == 0 {
		log.Success("nothing to undo")
		return nil
	}

	rightEdge := 0
	for _, s := range snaps {
		if w := 4 + len(s.filePath) + 2 + len("restored"); w > rightEdge {
			rightEdge = w
		}
	}

	restored := 0
	for _, s := range snaps {
		var curContent *string
		_ = d.Pool.QueryRow(ctx, `SELECT applied_sql FROM samna_migrate.file WHERE id = $1`, s.fileID).Scan(&curContent)

		if err := d.ExecUpgrade(ctx, `
			UPDATE samna_migrate.file SET
			    sha256         = $1,
			    applied_sha256 = $1,
			    applied_sql    = $2,
			    size_bytes     = $3,
			    updated_at     = now()
			WHERE id = $4`, s.sha, s.content, s.size, s.fileID); err != nil {
			return err
		}

		notes := fmt.Sprintf("restored %s to %s", s.filePath, shortSha(s.sha))
		_, err := d.Pool.Exec(ctx, `
			INSERT INTO samna_migrate.history (file_id, step_name, file_path, file_name, sha256,
			                                    applied_sql, action_type, tool_version, executed_by, host, database,
			                                    duration_ms, success, started_at, ended_at, undoing_history_id, notes)
			VALUES ($1, 'rebase', $2, $3, $4, $5, 'rebase_undo', $6, $7, $8, $9, 0, true, now(), now(), $10, $11)`,
			s.fileID, s.filePath, baseName(s.filePath), s.sha, s.content, cli.Version, cfg.PGUser, host, cfg.PGDatabase, s.histID, notes)
		if err != nil {
			return err
		}

		log.Step(s.filePath, "restored", rightEdge)
		log.Detail("      to %s from snapshot %d", shortSha(s.sha), s.histID)
		if log.Level == log.LevelVerbose {
			reconcile.PrintDiff(derefStr(curContent), derefStr(s.content))
		}
		restored++
	}

	log.Plain("")
	log.Success("restored %d file(s)", restored)
	return refreshLock(ctx, d, cfg)
}

func runRebasePrune(ctx context.Context, d *db.DB, cfg *config.Config, stepsCfg *steps.Config) error {
	host := hostOrLocalhost(cfg)
	disk := map[string]bool{}
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return err
		}
		for _, f := range files {
			disk[f.Rel] = true
		}
	}

	type orphan struct {
		id      int
		path    string
		sha     string
		content *string
		size    int
	}
	rows, err := d.Pool.Query(ctx, `
		SELECT id, file_path, COALESCE(applied_sha256, sha256, ''), applied_sql, COALESCE(size_bytes, 0)
		FROM samna_migrate.file
		WHERE state = 'applied' AND step_type = 'migration' AND removed_at IS NULL
		ORDER BY position`)
	if err != nil {
		return err
	}
	var orphans []orphan
	for rows.Next() {
		var o orphan
		if err := rows.Scan(&o.id, &o.path, &o.sha, &o.content, &o.size); err != nil {
			rows.Close()
			return err
		}
		if !disk[o.path] {
			orphans = append(orphans, o)
		}
	}
	rows.Close()

	if len(orphans) == 0 {
		log.Success("no orphaned migration entries to prune")
		return nil
	}

	log.Header(fmt.Sprintf("rebase --prune: fold %d orphaned migration entry(s) in %s", len(orphans), cfg.PGDatabase))
	rightEdge := 0
	paths := make([]string, len(orphans))
	for i, o := range orphans {
		paths[i] = o.path
		if w := 4 + len(o.path) + 2 + len("folded"); w > rightEdge {
			rightEdge = w
		}
	}

	if err := confirmPrune(cfg, paths); err != nil {
		return err
	}

	pruned := 0
	for _, o := range orphans {
		if err := d.ExecUpgrade(ctx, `
			UPDATE samna_migrate.file SET
			    state            = 'folded',
			    folded_at        = now(),
			    state_changed_at = now(),
			    updated_at       = now()
			WHERE id = $1`, o.id); err != nil {
			return err
		}
		notes := fmt.Sprintf("folded orphaned migration absent from source tree reason=%s", rebaseReason)
		_, err := d.Pool.Exec(ctx, `
			INSERT INTO samna_migrate.history (file_id, step_name, file_path, file_name, sha256, size_bytes,
			                                    applied_sql, action_type, tool_version, executed_by, host, database,
			                                    duration_ms, success, started_at, ended_at, notes)
			VALUES ($1, 'rebase', $2, $3, $4, $5, $6, 'fold', $7, $8, $9, $10, 0, true, now(), now(), $11)`,
			o.id, o.path, baseName(o.path), o.sha, o.size, o.content, cli.Version, cfg.PGUser, host, cfg.PGDatabase, notes)
		if err != nil {
			return err
		}
		log.Step(o.path, "folded", rightEdge)
		pruned++
	}

	log.Plain("")
	log.Success("folded %d orphaned entry(s)", pruned)
	return refreshLock(ctx, d, cfg)
}

func confirmPrune(cfg *config.Config, files []string) error {
	if assumeYes {
		return nil
	}
	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 {
		return fmt.Errorf("rebase --prune requires an interactive tty; use --yes to bypass")
	}
	summary := fmt.Sprintf("%d file(s)", len(files))
	if len(files) <= 8 {
		summary = strings.Join(files, ", ")
	}
	fmt.Printf("\nrebase --prune folds applied migration entries that are absent from the source tree.\n  database: %s@%s\n  entries:  %s\n\nType %s to confirm: ",
		cfg.PGDatabase, hostOrLocalhost(cfg), summary, cfg.PGDatabase)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	if strings.TrimSpace(line) != cfg.PGDatabase {
		return fmt.Errorf("confirmation mismatch, aborting")
	}
	return nil
}

func refreshLock(ctx context.Context, d *db.DB, cfg *config.Config) error {
	refreshed, err := lock.RefreshIfPresent(ctx, d, dbDir, cfg.PGDatabase, cli.Version)
	if err != nil {
		return err
	}
	if refreshed {
		log.Info("refreshed %s", lock.Path(dbDir))
	}
	return nil
}

func confirmRebase(cfg *config.Config, files []string) error {
	if assumeYes {
		return nil
	}
	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 {
		return fmt.Errorf("rebase requires an interactive tty; use --yes to bypass")
	}
	summary := fmt.Sprintf("%d file(s)", len(files))
	if len(files) <= 8 {
		summary = strings.Join(files, ", ")
	}
	fmt.Printf("\nrebase mirrors local files into samna_migrate as the deployed truth.\n  database: %s@%s\n  files:    %s\n\nType %s to confirm: ",
		cfg.PGDatabase, hostOrLocalhost(cfg), summary, cfg.PGDatabase)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	if strings.TrimSpace(line) != cfg.PGDatabase {
		return fmt.Errorf("confirmation mismatch, aborting")
	}
	return nil
}

func hostOrLocalhost(cfg *config.Config) string {
	if cfg.PGHost == "" {
		return "localhost"
	}
	return cfg.PGHost
}

func derefStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func baseName(fp string) string {
	if i := strings.LastIndex(fp, "/"); i >= 0 {
		return fp[i+1:]
	}
	return fp
}

func init() {
	rebaseCmd.Flags().StringVar(&rebaseReason, "reason", "", "Why the files are being mirrored, recorded in history")
	rebaseCmd.Flags().BoolVar(&rebaseUndo, "undo", false, "Restore the most recent rebase snapshot for each target file")
	rebaseCmd.Flags().IntVar(&rebaseUndoID, "undo-id", 0, "Restore one specific rebase snapshot by history id")
	rebaseCmd.Flags().BoolVar(&rebasePrune, "prune", false, "Fold applied migration entries absent from the source tree, clearing the boot blocker a history squash leaves")
	rootCmd.AddCommand(rebaseCmd)
}

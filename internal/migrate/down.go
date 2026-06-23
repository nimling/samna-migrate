package migrate

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nimling/samna-migrate/internal/agent"
	"github.com/nimling/samna-migrate/internal/anthropic"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/tools"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	downTo     string
	downSteps  int
	downDryRun bool
)

var downCmd = &cobra.Command{
	Use:   "down",
	Short: "Revert applied migrations step by step using an Anthropic-powered agent to synthesize down SQL.",
	Long: `Walks applied migration rows in descending applied_position order and reverts each one.

For each step:
  - Reuse a cached samna_migrate.down_proposal if one exists for the forward sha.
  - Otherwise invoke the Anthropic Messages API with built-in tools that read the
    forward SQL and inspect the current database state, then synthesize the down SQL.
  - Validate the synthesized SQL inside a rollback transaction.
  - Execute the down SQL under the step's envelope (or claimius.replay_mode='true' by default).
  - Mark the file row state='reverted' and write a history row with action_type='down'
    and undoing_history_id pointing back at the original apply row.

Requires --anthropic-key or the ANTHROPIC_API_KEY env var. Refuses to run in CI.
`,
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
		if cfg.IsCI() {
			return fmt.Errorf("smig down is local only and refuses to run in CI")
		}
		key := cli.AnthropicKey
		if key == "" {
			key = os.Getenv("ANTHROPIC_API_KEY")
		}
		if key == "" {
			return fmt.Errorf("missing --anthropic-key or ANTHROPIC_API_KEY")
		}
		if downTo == "" && downSteps == 0 {
			return fmt.Errorf("specify --to <file_path|id> or --steps <n>")
		}
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		if err := bootCheck(ctx, d, stepsFile, dbDir, cli.Version); err != nil {
			return err
		}

		targets, err := resolveDownTargets(ctx, d, downTo, downSteps)
		if err != nil {
			return err
		}
		if len(targets) == 0 {
			log.Info("no applied migrations to revert")
			return nil
		}
		log.Header(fmt.Sprintf("smig down: %d step(s)", len(targets)))

		client := anthropic.New(key)
		toolCtx := tools.New(d, dbDir)
		loop := &agent.Loop{Client: client, Tools: toolCtx, Model: cli.Model}

		for i, t := range targets {
			log.Plain("[%d/%d] reverting %s", i+1, len(targets), t.FilePath)
			downSQL, source, err := getDownSQL(ctx, d, loop, t, dbDir)
			if err != nil {
				return fmt.Errorf("synthesize down for %s: %w", t.FilePath, err)
			}
			log.Info("  source: %s (%d bytes)", source, len(downSQL))
			if downDryRun {
				log.Plain("--- proposed down SQL ---\n%s", downSQL)
				continue
			}
			if err := executeDown(ctx, d, t, downSQL, cfg); err != nil {
				return fmt.Errorf("execute down for %s: %w", t.FilePath, err)
			}
		}
		log.Success("down complete")
		return nil
	},
}

func init() {
	downCmd.Flags().StringVar(&downTo, "to", "", "Revert until reaching this file_path or history id")
	downCmd.Flags().IntVar(&downSteps, "steps", 0, "Revert N most recent applied migrations")
	downCmd.Flags().BoolVar(&downDryRun, "dry-run", false, "Print the proposed down SQL without executing")
	rootCmd.AddCommand(downCmd)
}

type target struct {
	FileID         int
	FilePath       string
	StepName       string
	ForwardSha     string
	AppliedHistID  int
	AppliedPos     *int
}

func resolveDownTargets(ctx context.Context, d *db.DB, to string, steps int) ([]target, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, file_path, step_name, applied_sha256, applied_history_id, applied_position
		FROM samna_migrate.file
		WHERE state = 'applied' AND step_type = 'migration'
		ORDER BY applied_position DESC NULLS LAST`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var all []target
	for rows.Next() {
		var t target
		var sha *string
		var histID *int
		if err := rows.Scan(&t.FileID, &t.FilePath, &t.StepName, &sha, &histID, &t.AppliedPos); err != nil {
			return nil, err
		}
		if sha != nil {
			t.ForwardSha = *sha
		}
		if histID != nil {
			t.AppliedHistID = *histID
		}
		all = append(all, t)
	}
	if steps > 0 {
		if steps > len(all) {
			steps = len(all)
		}
		return all[:steps], nil
	}
	out := []target{}
	for _, t := range all {
		out = append(out, t)
		if t.FilePath == to || fmt.Sprintf("%d", t.AppliedHistID) == to {
			return out, nil
		}
	}
	return nil, fmt.Errorf("target not found: %s", to)
}

func getDownSQL(ctx context.Context, d *db.DB, loop *agent.Loop, t target, dbDir string) (string, string, error) {
	var sql string
	var execAt, succ any
	_ = execAt
	_ = succ
	err := d.Pool.QueryRow(ctx, `
		SELECT proposed_sql FROM samna_migrate.down_proposal
		WHERE file_id = $1 AND forward_sha256 = $2 AND accepted_at IS NOT NULL
		ORDER BY id DESC LIMIT 1`, t.FileID, t.ForwardSha).Scan(&sql)
	if err == nil && sql != "" {
		return sql, "cached proposal", nil
	}

	forwardPath := filepath.Join(dbDir, t.FilePath)
	forward, err := os.ReadFile(forwardPath)
	if err != nil {
		return "", "", err
	}
	result, err := loop.Run(ctx, t.FilePath, string(forward))
	if err != nil {
		return "", "", err
	}
	promptHash := promptHashOf(t.FilePath, string(forward))
	_, err = d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.down_proposal
		    (file_id, forward_sha256, model, prompt_hash, proposed_sql, accepted_at)
		VALUES ($1, $2, $3, $4, $5, now())`,
		t.FileID, t.ForwardSha, loop.Model, promptHash, result.DownSQL)
	if err != nil {
		return "", "", fmt.Errorf("cache proposal: %w", err)
	}

	downDisk := strings.TrimSuffix(forwardPath, ".sql") + ".down.sql"
	_ = os.WriteFile(downDisk, []byte(result.DownSQL), 0o644)
	return result.DownSQL, fmt.Sprintf("agent (%d tokens)", result.Tokens), nil
}

func executeDown(ctx context.Context, d *db.DB, t target, downSQL string, cfg *config.Config) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, "SET LOCAL claimius.replay_mode = 'true'"); err != nil {
		// not fatal if claimius is absent
		_ = err
	}
	if _, err := tx.Exec(ctx, downSQL); err != nil {
		return fmt.Errorf("exec down sql: %w", err)
	}

	var histID int
	notes := fmt.Sprintf("file_id=%d undoing applied_history_id=%d", t.FileID, t.AppliedHistID)
	err = tx.QueryRow(ctx, `
		INSERT INTO samna_migrate.history (
		    file_id, step_name, step_type, slug, file_name, file_path, sha256,
		    attempt, action_type, tool_version, executed_by, host, database,
		    duration_ms, success, started_at, ended_at, applied_at,
		    undoing_history_id, notes
		) VALUES (
		    $1, $2, 'migration', 'down', $3, $4, $5,
		    1, 'down', $6, $7, $8, $9,
		    0, true, now(), now(), now(),
		    NULLIF($10, 0), $11
		) RETURNING id`,
		t.FileID, t.StepName, filepath.Base(t.FilePath), t.FilePath, t.ForwardSha,
		cfg.PGUser, hostOf(cfg), cfg.PGDatabase, t.AppliedHistID, notes).Scan(&histID)
	if err != nil {
		return fmt.Errorf("write history: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE samna_migrate.file SET
		    state                   = 'reverted',
		    state_changed_at        = now(),
		    last_attempt_at         = now(),
		    last_attempt_status     = 'success',
		    last_attempt_history_id = $1,
		    updated_at              = now()
		WHERE id = $2`, histID, t.FileID); err != nil {
		return fmt.Errorf("mark reverted: %w", err)
	}
	if _, err := tx.Exec(ctx, `
		UPDATE samna_migrate.down_proposal SET
		    executed_at = now(),
		    succeeded   = true
		WHERE file_id = $1 AND forward_sha256 = $2
		  AND accepted_at IS NOT NULL`, t.FileID, t.ForwardSha); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func hostOf(c *config.Config) string {
	if c.PGHost == "" {
		return "localhost"
	}
	return c.PGHost
}

func promptHashOf(filePath, forward string) string {
	h := sha256.New()
	h.Write([]byte(filePath))
	h.Write([]byte{0})
	h.Write([]byte(forward))
	return hex.EncodeToString(h.Sum(nil))
}

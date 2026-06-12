package apply

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
)

type Pending struct {
	ID       int
	FilePath string
	FileName string
	StepName string
	StepType string
	Slug     string
	Version  *string
	Sha      string
	Size     int64
	Position int
}

func ListPending(ctx context.Context, d *db.DB) ([]Pending, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT id, file_path, file_name, step_name, step_type, slug, version,
		       sha256, size_bytes, position
		FROM samna_migrate.file
		WHERE state = 'pending'
		ORDER BY position`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Pending{}
	for rows.Next() {
		var p Pending
		var ver *string
		if err := rows.Scan(&p.ID, &p.FilePath, &p.FileName, &p.StepName, &p.StepType, &p.Slug, &ver,
			&p.Sha, &p.Size, &p.Position); err != nil {
			return nil, err
		}
		p.Version = ver
		out = append(out, p)
	}
	return out, rows.Err()
}

// File runs a single pending file via psql with the step's `pre` SQL prefix.
func File(ctx context.Context, d *db.DB, p Pending, st *steps.Step, dbDir, toolVersion, executedBy, host, database string) error {
	abs := dbDir + "/" + p.FilePath
	if _, err := os.Stat(abs); err != nil {
		return fmt.Errorf("file missing on disk: %s", abs)
	}
	yamlSha, _ := schema.GetYAMLSha(ctx, d)

	start := time.Now()
	preSQL := ""
	var vars map[string]string
	if st != nil {
		if st.Pre != "" {
			preSQL = st.Pre
		}
		expanded, err := st.ExpandVars()
		if err != nil {
			return err
		}
		vars = expanded
	}
	runErr := d.RunPsqlFile(ctx, abs, preSQL, vars)
	end := time.Now()
	durMs := end.Sub(start).Milliseconds()

	success := runErr == nil
	errMsg := ""
	if runErr != nil {
		errMsg = runErr.Error()
	}

	var attempt int
	_ = d.Pool.QueryRow(ctx, `SELECT attempt_count + 1 FROM samna_migrate.file WHERE id = $1`, p.ID).Scan(&attempt)
	if attempt == 0 {
		attempt = 1
	}

	var histID int
	err := d.Pool.QueryRow(ctx, `
		INSERT INTO samna_migrate.history
		    (file_id, step_name, step_type, slug, version, file_name, file_path,
		     sha256, size_bytes, attempt, action_type, tool_version,
		     executed_by, host, database, duration_ms, success, error_message,
		     started_at, ended_at, position, yaml_sha256, applied_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'apply', $11,
		        $12, $13, $14, $15, $16, NULLIF($17, ''),
		        $18, $19, $20, NULLIF($21, ''), now())
		RETURNING id`,
		p.ID, p.StepName, p.StepType, p.Slug, p.Version, p.FileName, p.FilePath,
		p.Sha, p.Size, attempt, toolVersion,
		executedBy, host, database, durMs, success, errMsg,
		start, end, p.Position, yamlSha,
	).Scan(&histID)
	if err != nil {
		return fmt.Errorf("write history: %w", err)
	}

	if success {
		_, err = d.Pool.Exec(ctx, `
			UPDATE samna_migrate.file SET
			    state                   = 'applied',
			    state_changed_at        = now(),
			    applied_at              = now(),
			    applied_history_id      = $1,
			    applied_sha256          = $2,
			    applied_position        = position,
			    last_applied_at         = now(),
			    last_applied_history_id = $1,
			    last_attempt_at         = now(),
			    last_attempt_status     = 'success',
			    last_attempt_history_id = $1,
			    attempt_count           = $3,
			    attempts_count          = $3,
			    updated_at              = now()
			WHERE id = $4`, histID, p.Sha, attempt, p.ID)
		if err != nil {
			return fmt.Errorf("mark applied: %w", err)
		}
		return nil
	}

	_, err = d.Pool.Exec(ctx, `
		UPDATE samna_migrate.file SET
		    last_attempt_at         = now(),
		    last_attempt_status     = 'failure',
		    last_attempt_history_id = $1,
		    attempt_count           = $2,
		    attempts_count          = $2,
		    updated_at              = now()
		WHERE id = $3`, histID, attempt, p.ID)
	if err != nil {
		return fmt.Errorf("mark failure: %w", err)
	}
	return runErr
}

func FileRel(stepsCfg *steps.Config, fp string, dbDir string) (*steps.Step, error) {
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			if f.Rel == fp {
				return &st, nil
			}
		}
	}
	return nil, fmt.Errorf("step not found for %s", fp)
}

// scanRowErr is a sentinel for missing rows surfaced upstream.
var _ = pgx.ErrNoRows

// suppressUnused keeps log used at package scope even if branches removed.
var _ = log.Info

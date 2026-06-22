package preflight

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/jackc/pgx/v5"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
)

type Report struct {
	YAMLDrift     bool
	YAMLDiskSha   string
	YAMLDBSha     string
	FilesNew      int
	FilesUnchanged int
	FilesDrift    int
	FilesRebased  int
	FilesMissing  int
}

// Scan walks the steps file from disk against the ledger.
// Returns the report and an error only on fatal mismatch.
func Scan(ctx context.Context, d *db.DB, cfg *schema.YAMLSnapshot, stepsCfg *steps.Config, dbDir string) (*Report, error) {
	r := &Report{}

	r.YAMLDBSha = cfg.YAMLSha
	r.YAMLDiskSha = cfg.DiskYAMLSha
	r.YAMLDrift = r.YAMLDBSha != r.YAMLDiskSha

	onDisk := map[string]bool{}

	for _, st := range stepsCfg.Steps {
		if !st.Active() {
			log.Detail("  step %s skipped, if condition false", st.Name)
			continue
		}
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			onDisk[f.Rel] = true
			disksha, err := hash.File(f.AbsPath)
			if err != nil {
				return nil, fmt.Errorf("hash %s: %w", f.AbsPath, err)
			}
			size, _ := hash.Size(f.AbsPath)

			var dbSha, dbState string
			err = d.Pool.QueryRow(ctx,
				`SELECT sha256, state FROM samna_migrate.file WHERE file_path = $1`,
				f.Rel).Scan(&dbSha, &dbState)
			if err == pgx.ErrNoRows {
				ver, slug, _, _ := steps.ParseFilename(f.Name)
				if slug == "" {
					slug = st.Slug
				}
				_, err := d.Pool.Exec(ctx, `
					INSERT INTO samna_migrate.file
					(step_name, step_type, slug, version, file_name, file_path,
					 sha256, size_bytes, state, position)
					VALUES ($1, $2, $3, NULLIF($4, ''), $5, $6, $7, $8, 'pending',
					        COALESCE((SELECT MAX(position) FROM samna_migrate.file), 0) + 1)`,
					st.Name, st.Type, slug, ver, f.Name, f.Rel, disksha, size)
				if err != nil {
					return nil, fmt.Errorf("discover %s: %w", f.Rel, err)
				}
				r.FilesNew++
				continue
			}
			if err != nil {
				return nil, err
			}

			if dbSha == disksha {
				r.FilesUnchanged++
				continue
			}

			if st.Type == "migration" && dbState == "applied" {
				return r, fmt.Errorf("tampered: %s (db=%s disk=%s)", f.Rel, dbSha[:12], disksha[:12])
			}

			r.FilesDrift++
			if dbState == "applied" {
				log.Plain("  %s drift, replaying base step file", f.Rel)
				err = d.ExecUpgrade(ctx, `
					UPDATE samna_migrate.file
					SET sha256 = $1, size_bytes = $2, state = 'pending',
					    state_changed_at = now(), updated_at = now()
					WHERE file_path = $3`, disksha, size, f.Rel)
			} else {
				err = d.ExecUpgrade(ctx, `
					UPDATE samna_migrate.file
					SET sha256 = $1, size_bytes = $2, updated_at = now()
					WHERE file_path = $3`, disksha, size, f.Rel)
			}
			if err != nil {
				return nil, fmt.Errorf("requeue %s: %w", f.Rel, err)
			}
		}
	}

	rows, err := d.Pool.Query(ctx, `
		SELECT file_path, step_type FROM samna_migrate.file
		WHERE state = 'applied' AND removed_at IS NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var fp, st string
		if err := rows.Scan(&fp, &st); err != nil {
			return nil, err
		}
		if onDisk[fp] {
			continue
		}
		if _, err := os.Stat(filepath.Join(dbDir, fp)); err == nil {
			continue
		}
		r.FilesMissing++
		if st == "migration" {
			return r, fmt.Errorf("missing on disk: %s is applied but absent from the source tree", fp)
		}
		log.Warn("  %s applied but missing on disk", fp)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	return r, nil
}

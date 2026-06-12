package schema

import (
	"context"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
)

type YAMLSnapshot struct {
	StepsFile   string
	DiskYAMLSha string
	YAMLSha     string // value in samna_migrate.state
}

func Snapshot(ctx context.Context, d *db.DB, stepsFile string) (*YAMLSnapshot, error) {
	disk, err := hash.File(stepsFile)
	if err != nil {
		return nil, err
	}
	stored, err := GetYAMLSha(ctx, d)
	if err != nil {
		return nil, err
	}
	return &YAMLSnapshot{StepsFile: stepsFile, DiskYAMLSha: disk, YAMLSha: stored}, nil
}

func WriteYAMLSha(ctx context.Context, d *db.DB, newSha, toolVersion string) error {
	_, err := d.Pool.Exec(ctx, `
		UPDATE samna_migrate.state SET
		    yaml_prior_sha256       = yaml_sha256,
		    yaml_prior_observed_at  = yaml_observed_at,
		    yaml_sha256             = $1,
		    yaml_observed_at        = now(),
		    tool_version            = $2,
		    updated_at              = now()
		WHERE id = 1`, newSha, toolVersion)
	return err
}

package upgrade

import (
	"context"
	_ "embed"
	"fmt"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/schema"
)

//go:embed sql/upgrade_to_1.sql
var upgradeTo1SQL string

//go:embed sql/upgrade_to_2.sql
var upgradeTo2SQL string

//go:embed sql/upgrade_to_3.sql
var upgradeTo3SQL string

//go:embed sql/upgrade_to_4.sql
var upgradeTo4SQL string

//go:embed sql/upgrade_to_5.sql
var upgradeTo5SQL string

//go:embed sql/upgrade_to_6.sql
var upgradeTo6SQL string

//go:embed sql/upgrade_to_7.sql
var upgradeTo7SQL string

const TargetVersion = 7

func stepSQL(version int) (string, error) {
	switch version {
	case 1:
		return upgradeTo1SQL, nil
	case 2:
		return upgradeTo2SQL, nil
	case 3:
		return upgradeTo3SQL, nil
	case 4:
		return upgradeTo4SQL, nil
	case 5:
		return upgradeTo5SQL, nil
	case 6:
		return upgradeTo6SQL, nil
	case 7:
		return upgradeTo7SQL, nil
	default:
		return "", fmt.Errorf("no upgrade step defined for %d", version)
	}
}

// Chain walks the samna_migrate schema chain from the current version to the
// target, applying each step in its own upgrade-mode transaction.
func Chain(ctx context.Context, d *db.DB, toolVersion string) error {
	current, err := schema.GetSchemaVersion(ctx, d)
	if err != nil {
		return err
	}
	for next := current + 1; next <= TargetVersion; next++ {
		sql, err := stepSQL(next)
		if err != nil {
			return err
		}
		tx, err := d.Pool.Begin(ctx)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "SET LOCAL samna_migrate.upgrade_mode = 'true'"); err != nil {
			tx.Rollback(ctx)
			return err
		}
		if _, err := tx.Exec(ctx, sql); err != nil {
			tx.Rollback(ctx)
			return fmt.Errorf("upgrade_to_%d: %w", next, err)
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		if err := schema.SetSchemaVersion(ctx, d, next, toolVersion); err != nil {
			return err
		}
	}
	return nil
}

// Apply brings samna_migrate to the latest schema version and reconciles the
// recorded migrate.yml against disk. The upgrade command calls it with announce
// to report progress; the boot check calls it silently to initialize a fresh
// database before the requested command runs.
func Apply(ctx context.Context, d *db.DB, stepsFile, toolVersion string, announce bool) error {
	if err := schema.Ensure(ctx, d); err != nil {
		return err
	}
	from, err := schema.GetSchemaVersion(ctx, d)
	if err != nil {
		return err
	}
	if err := Chain(ctx, d, toolVersion); err != nil {
		return err
	}
	if announce && from < TargetVersion {
		log.Info("schema chain %d -> %d", from, TargetVersion)
	}
	snap, err := schema.Snapshot(ctx, d, stepsFile)
	if err != nil {
		return err
	}
	if snap.DiskYAMLSha == snap.YAMLSha {
		if announce {
			log.Info("migrate.yml unchanged")
		}
		_, err = d.Pool.Exec(ctx,
			`UPDATE samna_migrate.state SET tool_version = $1, updated_at = now() WHERE id = 1`,
			toolVersion)
		return err
	}
	if announce {
		if snap.YAMLSha == "" {
			log.Info("migrate.yml first observation %s", snap.DiskYAMLSha[:12])
		} else {
			log.Warn("migrate.yml drift %s -> %s", snap.YAMLSha[:12], snap.DiskYAMLSha[:12])
		}
	}
	return schema.WriteYAMLSha(ctx, d, snap.DiskYAMLSha, toolVersion)
}

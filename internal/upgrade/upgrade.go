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

// Chain walks the schema upgrade chain from current to target.
func Chain(ctx context.Context, d *db.DB, toolVersion string) error {
	current, err := schema.GetSchemaVersion(ctx, d)
	if err != nil {
		return err
	}
	for v := current; v < TargetVersion; v++ {
		next := v + 1
		log.Plain("applying upgrade step %d -> %d", v, next)
		var sql string
		switch next {
		case 1:
			sql = upgradeTo1SQL
		case 2:
			sql = upgradeTo2SQL
		case 3:
			sql = upgradeTo3SQL
		default:
			return fmt.Errorf("no upgrade step defined for %d", next)
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
		log.Success("samna_migrate at version %d", next)
	}
	return nil
}

const TargetVersion = 3

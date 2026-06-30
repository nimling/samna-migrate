package migrate

import (
	"context"
	"fmt"
	"os"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/require"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
)

// bootCheck verifies the db is aligned with the script before a command proceeds.
// A fresh database is initialized to the latest schema version in place; an
// existing database left behind by an invalid version stops and asks for upgrade.
func bootCheck(ctx context.Context, d *db.DB, stepsFile, dbDir, toolVersion string) error {
	initialized, err := schema.Initialized(ctx, d)
	if err != nil {
		return err
	}
	if !initialized {
		if err := upgrade.Apply(ctx, d, stepsFile, toolVersion, false); err != nil {
			return err
		}
	}
	current, err := schema.GetSchemaVersion(ctx, d)
	if err != nil {
		return err
	}
	if current > cli.SchemaVersion {
		return fmt.Errorf("database was touched by a newer migrate tool: db schema_version=%d, this tool=%d", current, cli.SchemaVersion)
	}
	if current < cli.SchemaVersion {
		return fmt.Errorf("samna_migrate schema behind. Run 'migrate upgrade': db schema_version=%d, this tool=%d", current, cli.SchemaVersion)
	}
	dbTool, err := schema.GetToolVersion(ctx, d)
	if err != nil {
		return err
	}
	if dbTool == "" || dbTool != toolVersion {
		return fmt.Errorf("tool_version mismatch. Run 'migrate upgrade': db=%q, this tool=%q", dbTool, toolVersion)
	}
	if _, err := os.Stat(stepsFile); err != nil {
		return fmt.Errorf("migrate.yml not found at %s", stepsFile)
	}
	diskSha, err := hash.File(stepsFile)
	if err != nil {
		return err
	}
	dbSha, err := schema.GetYAMLSha(ctx, d)
	if err != nil {
		return err
	}
	if dbSha == "" {
		return fmt.Errorf("migrate.yml has not been acknowledged. Run 'migrate upgrade'")
	}
	if dbSha != diskSha {
		return fmt.Errorf("migrate.yml drift. Run 'migrate upgrade': db=%s disk=%s", dbSha[:12], diskSha[:12])
	}
	stepsCfg, err := steps.Load(stepsFile)
	if err != nil {
		return err
	}
	return require.Gate(ctx, d, stepsCfg, dbDir)
}

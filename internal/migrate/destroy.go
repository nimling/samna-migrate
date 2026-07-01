package migrate

import (
	"context"
	"fmt"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var destroyDryRun bool

var destroyCmd = &cobra.Command{
	Use:   "destroy",
	Short: "Drop every object the migrate.yml tree creates from the target database",
	Long: `Builds the migrate.yml tree into a throwaway postgres container, inventories exactly
the objects those files produce, then drops that set from the live database.

Declared schemas other than public are dropped with DROP SCHEMA CASCADE. Objects in
public are dropped individually with DROP ... IF EXISTS CASCADE. The samna_migrate
ledger is reset so every file returns to pending and a following up re-applies from
scratch. Requires docker for the candidate build.`,
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
		if !reconcile.DockerPresent() {
			return fmt.Errorf("destroy needs docker to build the candidate tree")
		}
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}
		schemas := reconcile.SchemaUnion(stepsCfg)

		log.Header("destroy: build candidate to learn what the tree creates")
		cd, err := reconcile.CompareToLive(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{})
		if err != nil {
			return err
		}
		for _, be := range cd.BuildErrors {
			log.Warn("  build error %s: %s", be.File, be.Err)
		}
		if len(cd.BuildErrors) > 0 {
			log.Warn("candidate incomplete, the plan may miss objects those files would create")
		}

		plan := data.PlanDrop(cd.Candidate(), schemas)
		if plan.Empty() {
			log.Success("nothing the tree creates is present, database untouched")
			return nil
		}

		log.Header(fmt.Sprintf("destroy plan: %s", cfg.PGDatabase))
		for _, s := range plan.Schemas {
			log.Warn("  DROP SCHEMA %s CASCADE", s)
		}
		for _, o := range plan.Objects {
			log.Warn("  %s %s", o.Kind, o.Ident)
		}
		log.Info("%d schema(s), %d object(s) in public", len(plan.Schemas), len(plan.Objects))

		if destroyDryRun {
			log.Info("dry run: nothing dropped")
			return nil
		}
		if err := confirmDatabase(cfg, "smig destroy"); err != nil {
			return err
		}

		if err := executeDestroy(ctx, d, plan); err != nil {
			return err
		}
		log.Success("destroyed %d schema(s) and %d object(s)", len(plan.Schemas), len(plan.Objects))
		return nil
	},
}

func executeDestroy(ctx context.Context, d *db.DB, plan *data.DropPlan) error {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, s := range plan.Schemas {
		if _, err := tx.Exec(ctx, fmt.Sprintf(`DROP SCHEMA IF EXISTS %s CASCADE`, data.QuoteIdent(s))); err != nil {
			return fmt.Errorf("drop schema %s: %w", s, err)
		}
	}
	for _, o := range plan.Objects {
		if _, err := tx.Exec(ctx, o.SQL); err != nil {
			return fmt.Errorf("drop %s %s: %w", o.Kind, o.Ident, err)
		}
	}
	var hasFile bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.tables
			WHERE table_schema = 'samna_migrate' AND table_name = 'file')`).Scan(&hasFile); err != nil {
		return err
	}
	if hasFile {
		if _, err := tx.Exec(ctx, `
			UPDATE samna_migrate.file SET
			    state                   = 'pending',
			    state_changed_at        = now(),
			    applied_at              = NULL,
			    applied_history_id      = NULL,
			    applied_sha256          = NULL,
			    applied_sql             = NULL,
			    applied_commit          = NULL,
			    applied_position        = NULL,
			    last_applied_at         = NULL,
			    last_applied_history_id = NULL,
			    updated_at              = now()
			WHERE state <> 'pending'`); err != nil {
			return fmt.Errorf("reset ledger: %w", err)
		}
	}
	return tx.Commit(ctx)
}

func init() {
	destroyCmd.Flags().BoolVar(&destroyDryRun, "dry-run", false, "Print the destroy plan without dropping anything")
	rootCmd.AddCommand(destroyCmd)
}

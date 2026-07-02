package migrate

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	destroyDryRun     bool
	destroyExtensions bool
)

var destroyCmd = &cobra.Command{
	Use:   "destroy",
	Short: "Drop every object the migrate.yml tree creates from the target database",
	Long: `Builds the migrate.yml tree into a throwaway postgres container, inventories exactly
the objects those files produce, then drops that set from the live database.

Declared schemas other than public are dropped with DROP SCHEMA CASCADE. Objects in
public are dropped individually with DROP ... IF EXISTS CASCADE. Objects owned by an
extension, such as the functions pgcrypto installs, are excluded so the individual
drops do not fail. The samna_migrate ledger is always dropped so a following up
re-applies from scratch. With --extensions the extensions the tree creates are dropped
too (plpgsql is never dropped). Requires docker for the candidate build.`,
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
		extObjs, err := reconcile.ExtensionObjects(ctx, d, schemas)
		if err != nil {
			return err
		}
		if len(extObjs) > 0 {
			kept := plan.Objects[:0]
			for _, o := range plan.Objects {
				if _, owned := extObjs[o.Kind+" "+o.Ident]; owned {
					continue
				}
				kept = append(kept, o)
			}
			plan.Objects = kept
		}
		if destroyExtensions {
			for id := range cd.Candidate() {
				name, ok := strings.CutPrefix(id, "extension ")
				if !ok || name == "plpgsql" {
					continue
				}
				plan.Extensions = append(plan.Extensions, name)
			}
			sort.Strings(plan.Extensions)
		}
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
		for _, e := range plan.Extensions {
			log.Warn("  DROP EXTENSION %s CASCADE", e)
		}
		log.Warn("  DROP SCHEMA samna_migrate CASCADE")
		log.Info("%d schema(s), %d object(s) in public, %d extension(s)", len(plan.Schemas), len(plan.Objects), len(plan.Extensions))

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
		log.Success("destroyed %d schema(s), %d object(s), %d extension(s), and the samna_migrate ledger", len(plan.Schemas), len(plan.Objects), len(plan.Extensions))
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
	for _, e := range plan.Extensions {
		if _, err := tx.Exec(ctx, fmt.Sprintf(`DROP EXTENSION IF EXISTS %s CASCADE`, data.QuoteIdent(e))); err != nil {
			return fmt.Errorf("drop extension %s: %w", e, err)
		}
	}
	if _, err := tx.Exec(ctx, `DROP SCHEMA IF EXISTS samna_migrate CASCADE`); err != nil {
		return fmt.Errorf("drop ledger: %w", err)
	}
	return tx.Commit(ctx)
}

func init() {
	destroyCmd.Flags().BoolVar(&destroyDryRun, "dry-run", false, "Print the destroy plan without dropping anything")
	destroyCmd.Flags().BoolVar(&destroyExtensions, "extensions", false, "Also drop the extensions the tree creates (plpgsql is never dropped)")
	rootCmd.AddCommand(destroyCmd)
}

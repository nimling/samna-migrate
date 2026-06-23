package migrate

import (
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	reconcileKeep        bool
	reconcileImage       string
	reconcileStopOnError bool
	reconcileNoContainer bool
)

var reconcileCmd = &cobra.Command{
	Use:   "reconcile",
	Short: "Compare the local database folder against the live server in depth",
	Long: `reconcile runs three analyses of the local database folder against the live
server. The folder is --db-dir, default ./database.

File audit compares every local .sql file against the body stored in
samna_migrate when it was applied, classifies each file as added, dropped,
changed, or reordered, and pinpoints the function, table, or statement that
differs by file and line as a git style diff. It never stops on the first
difference unless --stop-one-error is given. Use -v for the diff hunks and -vv
for the full file bodies.

Live diagnostic introspects the target server directly and reports the
functions, tables, views, types, and sequences the local files define that are
missing from live, and the live objects no local file defines. No docker.

Container comparison starts a local docker postgres, applies every local file
into it, introspects the produced objects, and compares them object for object
against the live server. Pass --no-container to skip it. The files apply with
their step pre and vars expanded from the environment, so run reconcile with the
deploy env; a build failure is reported without stopping the other analyses.`,
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

		report, err := reconcile.Audit(ctx, d, stepsCfg, dbDir, reconcileStopOnError)
		if err != nil {
			return err
		}
		reconcile.Render(report)

		liveRep, err := reconcile.LiveCompare(ctx, d, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		reconcile.RenderLive(liveRep, cfg.PGDatabase+"@"+hostOrLocalhost(cfg))

		if reconcileNoContainer {
			return nil
		}
		log.Header("container comparison: local files built and diffed against live")
		diff, err := reconcile.CompareToLive(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{
			Keep:  reconcileKeep,
			Image: reconcileImage,
		})
		if err != nil {
			log.Err("container comparison failed: %v", err)
			return nil
		}
		reconcile.RenderContainerDiff(diff)
		return nil
	},
}

func init() {
	reconcileCmd.Flags().BoolVar(&reconcileKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	reconcileCmd.Flags().StringVar(&reconcileImage, "image", "", "Postgres docker image, defaults to the live server major version")
	reconcileCmd.Flags().BoolVar(&reconcileStopOnError, "stop-one-error", false, "Stop the file audit at the first difference instead of reporting all")
	reconcileCmd.Flags().BoolVar(&reconcileNoContainer, "no-container", false, "Skip the container comparison, run the file audit and live diagnostic only")
	rootCmd.AddCommand(reconcileCmd)
}

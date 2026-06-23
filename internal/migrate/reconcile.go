package migrate

import (
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	reconcileDryRun      bool
	reconcileKeep        bool
	reconcileImage       string
	reconcileStopOnError bool
	reconcileNoProof     bool
)

var reconcileCmd = &cobra.Command{
	Use:   "reconcile",
	Short: "Audit the local tree against the deployed state and prove it against a disposable postgres",
	Long: `reconcile runs two phases.

Audit compares every local .sql file against the body stored in samna_migrate
when it was applied. It reports added, dropped, changed, and reordered files,
pinpoints the function, table, or statement that differs by file and line, and
renders the difference as a git style diff. It never stops on the first
difference unless --stop-one-error is given. Use -v for the diff hunks and -vv
for the full file bodies.

Proof builds a candidate source tree from --db-dir, overlaying .upgraded/ when
it is present, bootstraps it into a disposable postgres container, and records
three verdicts:

  bootstrap     the candidate tree builds a fresh database without errors
  equality      the fresh database matches the live database object for object
  determinism   a second independent bootstrap matches the first

When .upgraded/ exists and all three pass, reconcile writes .upgraded/reconcile.json,
the proof that smig merge --apply requires unless --force is given. Pass --no-proof
to run the audit alone without docker.`,
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

		if reconcileNoProof {
			return nil
		}
		return reconcile.Run(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{
			DryRun: reconcileDryRun,
			Keep:   reconcileKeep,
			Image:  reconcileImage,
		})
	},
}

func init() {
	reconcileCmd.Flags().BoolVar(&reconcileDryRun, "dry-run", false, "Report verdicts without writing the proof manifest")
	reconcileCmd.Flags().BoolVar(&reconcileKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	reconcileCmd.Flags().StringVar(&reconcileImage, "image", "", "Postgres docker image, defaults to the live server major version")
	reconcileCmd.Flags().BoolVar(&reconcileStopOnError, "stop-one-error", false, "Stop the audit at the first difference instead of reporting all")
	reconcileCmd.Flags().BoolVar(&reconcileNoProof, "no-proof", false, "Run the file audit alone without the disposable container proof")
	rootCmd.AddCommand(reconcileCmd)
}

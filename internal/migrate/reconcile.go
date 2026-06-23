package migrate

import (
	"os"
	"path/filepath"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
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
	reconcileProof       bool
)

var reconcileCmd = &cobra.Command{
	Use:   "reconcile",
	Short: "Audit the local tree against the deployed state, and prove .upgraded/ against a disposable postgres",
	Long: `reconcile audits the local tree against the deployed state.

The audit compares every local .sql file against the body stored in samna_migrate
when it was applied. It reports added, dropped, changed, and reordered files,
pinpoints the function, table, or statement that differs by file and line, and
renders the difference as a git style diff. It never stops on the first
difference unless --stop-one-error is given. Use -v for the diff hunks and -vv
for the full file bodies.

When .upgraded/ is present, or with --proof, reconcile also bootstraps a candidate
tree into a disposable postgres container and records three verdicts:

  bootstrap     the candidate tree builds a fresh database without errors
  equality      the fresh database matches the live database object for object
  determinism   a second independent bootstrap matches the first

All three passing writes .upgraded/reconcile.json, the proof that smig merge --apply
requires unless --force is given. Without .upgraded/ and without --proof, reconcile
runs the audit alone and needs no docker.`,
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

		if !reconcileProof && !upgradedPresent(stepsFile) {
			log.Info("proof skipped, no .upgraded/ present. Pass --proof to bootstrap against a container")
			return nil
		}
		return reconcile.Run(ctx, d, cfg, stepsCfg, dbDir, cli.Version, reconcile.Options{
			DryRun: reconcileDryRun,
			Keep:   reconcileKeep,
			Image:  reconcileImage,
		})
	},
}

func upgradedPresent(stepsFile string) bool {
	entries, err := os.ReadDir(filepath.Join(filepath.Dir(stepsFile), ".upgraded"))
	return err == nil && len(entries) > 0
}

func init() {
	reconcileCmd.Flags().BoolVar(&reconcileDryRun, "dry-run", false, "Report verdicts without writing the proof manifest")
	reconcileCmd.Flags().BoolVar(&reconcileKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	reconcileCmd.Flags().StringVar(&reconcileImage, "image", "", "Postgres docker image, defaults to the live server major version")
	reconcileCmd.Flags().BoolVar(&reconcileStopOnError, "stop-one-error", false, "Stop the audit at the first difference instead of reporting all")
	reconcileCmd.Flags().BoolVar(&reconcileProof, "proof", false, "Run the container proof even when .upgraded/ is absent")
	rootCmd.AddCommand(reconcileCmd)
}

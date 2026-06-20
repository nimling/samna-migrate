package migrate

import (
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/verify"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	verifyDryRun bool
	verifyKeep   bool
	verifyImage  string
)

var verifyCmd = &cobra.Command{
	Use:   "verify",
	Short: "Prove the --db-dir tree against a disposable postgres container",
	Long: `Builds a candidate source tree from --db-dir, overlaying .upgraded/ when it
is present, bootstraps it into a disposable postgres container, and records
three verdicts:

  bootstrap   the candidate tree builds a fresh database without errors
  equality    the fresh database matches the live database object for object
  reapply     every base and seed file applies a second time without errors
              and without changing any object

When .upgraded/ exists the candidate is the merged tree and all three passing
writes .upgraded/verify.json, the proof that smig merge --apply requires unless
--force is given. When .upgraded/ is absent the --db-dir tree is verified as is,
so verify doubles as a standalone check that the current tree reproduces the
live database object for object.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			_ = config.LoadDotEnv(envFile)
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
		return verify.Run(ctx, d, cfg, stepsCfg, dbDir, cli.Version, verify.Options{
			DryRun: verifyDryRun,
			Keep:   verifyKeep,
			Image:  verifyImage,
		})
	},
}

func init() {
	verifyCmd.Flags().BoolVar(&verifyDryRun, "dry-run", false, "Report verdicts without writing the proof manifest")
	verifyCmd.Flags().BoolVar(&verifyKeep, "keep", false, "Leave the container and candidate tree in place for inspection")
	verifyCmd.Flags().StringVar(&verifyImage, "image", "", "Postgres docker image, defaults to the live server major version")
	rootCmd.AddCommand(verifyCmd)
}

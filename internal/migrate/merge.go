package migrate

import (
	"fmt"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/merge"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	mergeApply  bool
	mergeRevert bool
	mergeTag    bool
)

var mergeCmd = &cobra.Command{
	Use:   "merge [name]",
	Short: "Rebase local SQL into .upgraded/ from live database; --apply moves it in; --revert restores a prior snapshot",
	Long: `Three modes:

  merge              Pass 1 writes live SQL of every base and seed file into
                     .upgraded/. Pass 2 routes migration files into base targets
                     when their identifiers match. Source tree and database untouched.

  merge --apply      Snapshot the source tree to .migrate-<ts>-<sha>/ and move
                     .upgraded/ into the source tree. Reconcile samna_migrate.file
                     rows (folded migrations, rekeyed file rows). Requires the
                     proof written by smig reconcile unless --force is given.

  merge --revert [n] Restore a prior .migrate-<n>/ snapshot. Defaults to the most
                     recent one. Refuses unless the last merge action was an apply,
                     unless --force is given.`,
	Args: cobra.MaximumNArgs(1),
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

		switch {
		case mergeApply && mergeRevert:
			return fmt.Errorf("--apply and --revert are mutually exclusive")
		case mergeApply:
			return merge.Apply(ctx, d, cfg, stepsCfg, dbDir, cli.Version, mergeTag, force)
		case mergeRevert:
			target := ""
			if len(args) == 1 {
				target = args[0]
			}
			return merge.Revert(ctx, d, cfg, stepsCfg, dbDir, cli.Version, target, force)
		default:
			return merge.Rebase(ctx, d, cfg, stepsCfg, dbDir, cli.Version, force)
		}
	},
}

func init() {
	mergeCmd.Flags().BoolVar(&mergeApply, "apply", false, "Promote .upgraded/ into source tree")
	mergeCmd.Flags().BoolVar(&mergeRevert, "revert", false, "Restore a prior .migrate-<n>/ snapshot")
	mergeCmd.Flags().BoolVar(&mergeTag, "tag", false, "Create git annotated tag during apply")
	rootCmd.AddCommand(mergeCmd)
}

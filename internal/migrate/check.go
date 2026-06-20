package migrate

import (
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var checkCmd = &cobra.Command{
	Use:   "check",
	Short: "Preflight only. Validates equality and reports drift without applying.",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			_ = config.LoadDotEnv(envFile)
		}
		cfg := config.FromEnv()
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		if err := bootCheck(ctx, d, stepsFile, dbDir, cli.Version); err != nil {
			log.Err("%v", err)
			return err
		}
		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}
		snap, err := schema.Snapshot(ctx, d, stepsFile)
		if err != nil {
			return err
		}
		r, err := preflight.Scan(ctx, d, snap, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		log.Plain("  new=%d  unchanged=%d  drift=%d  missing=%d",
			r.FilesNew, r.FilesUnchanged, r.FilesDrift, r.FilesMissing)
		log.Success("preflight passed")
		return nil
	},
}

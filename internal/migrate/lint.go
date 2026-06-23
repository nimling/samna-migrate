package migrate

import (
	"fmt"
	"os"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/lint"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/spf13/cobra"
)

var lintStrict bool

var lintCmd = &cobra.Command{
	Use:   "lint",
	Short: "Static checks on every step file, no database needed",
	Long: `Walks every file in every step and reports:

  error  filename grammar violations on any step
  error  session_replication_role usage
  error  COMMENT ON FUNCTION without an argument signature
  error  locked files modified or missing, when ` + lock.FileName + ` exists
  warn   CREATE TYPE without a pg_type existence guard
  warn   CREATE INDEX, ADD COLUMN, or CREATE FUNCTION without their
         idempotent form in migration files

Errors exit nonzero. --strict treats warnings as errors.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if envFile != "" {
			if err := config.LoadDotEnv(envFile); err != nil {
				return err
			}
		}
		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}
		lockPath := lock.Path(dbDir)
		if _, err := os.Stat(lockPath); err != nil {
			lockPath = ""
		}
		r, err := lint.Run(stepsCfg, dbDir, lockPath)
		if err != nil {
			return err
		}
		for _, f := range r.Findings {
			if f.Level == "error" {
				log.Err("  %s  %s", f.File, f.Message)
			} else {
				log.Warn("  %s  %s", f.File, f.Message)
			}
		}
		if lockPath == "" {
			log.Info("no %s found, locked file checks skipped. Generate one with smig lock", lock.FileName)
		}
		log.Plain("errors=%d warnings=%d", r.Errors, r.Warnings)
		if r.Errors > 0 || (lintStrict && r.Warnings > 0) {
			return fmt.Errorf("lint failed")
		}
		log.Success("lint passed")
		return nil
	},
}

func init() {
	lintCmd.Flags().BoolVar(&lintStrict, "strict", false, "Treat warnings as errors")
	rootCmd.AddCommand(lintCmd)
}

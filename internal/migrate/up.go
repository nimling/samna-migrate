package migrate

import (
	"fmt"
	"os"
	"time"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var upCmd = &cobra.Command{
	Use:   "up",
	Short: "Apply pending migrations after preflight",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			if err := config.LoadDotEnv(envFile); err != nil {
				log.Warn("env: %v", err)
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
		snap, err := schema.Snapshot(ctx, d, stepsFile)
		if err != nil {
			return err
		}

		log.Header(fmt.Sprintf("migrate up: %s", cfg.PGDatabase))
		_, err = preflight.Scan(ctx, d, snap, stepsCfg, dbDir)
		if err != nil {
			return err
		}

		pendings, err := apply.ListPending(ctx, d)
		if err != nil {
			return err
		}
		if len(pendings) == 0 {
			log.Success("nothing pending")
			return nil
		}
		log.Info("%d pending file(s)", len(pendings))

		executedBy := cfg.PGUser
		host := cfg.PGHost
		if host == "" {
			host = "localhost"
		}
		hostName, _ := os.Hostname()
		_ = hostName

		applied := 0
		start := time.Now()
		for _, p := range pendings {
			st, _ := apply.FileRel(stepsCfg, p.FilePath, dbDir)
			fileStart := time.Now()
			if err := apply.File(ctx, d, p, st, dbDir, cli.Version, executedBy, host, cfg.PGDatabase); err != nil {
				return fmt.Errorf("%s failed: %w", p.FilePath, err)
			}
			log.Step(p.FilePath, fmt.Sprintf("  %s", time.Since(fileStart).Round(time.Millisecond)))
			applied++
		}
		log.Success("applied %d in %s", applied, time.Since(start).Round(time.Millisecond))

		refreshed, err := lock.RefreshIfPresent(ctx, d, dbDir, cfg.PGDatabase, cli.Version)
		if err != nil {
			log.Warn("lockfile refresh: %v", err)
		} else if refreshed {
			log.Info("refreshed %s", lock.Path(dbDir))
		}
		return nil
	},
}

package migrate

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var upgradeCmd = &cobra.Command{
	Use:   "upgrade",
	Short: "Walk the samna_migrate schema chain and reconcile state. Local only.",
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
		if err := confirmUpgrade(cfg); err != nil {
			return err
		}
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		if err := schema.Ensure(ctx, d); err != nil {
			return err
		}
		if force {
			if _, err := d.Pool.Exec(ctx, `UPDATE samna_migrate.state SET schema_version = 0 WHERE id = 1`); err != nil {
				return err
			}
			log.Warn("--force: reset schema_version to 0")
		}
		log.Header("migrate upgrade")
		log.Info("Phase A: schema chain target=%d", upgrade.TargetVersion)
		if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
			return err
		}
		log.Info("Phase B: reconcile state with disk")
		snap, err := schema.Snapshot(ctx, d, stepsFile)
		if err != nil {
			return err
		}
		if snap.DiskYAMLSha != snap.YAMLSha {
			if snap.YAMLSha == "" {
				log.Info("  migrate.yml first observation %s", snap.DiskYAMLSha[:12])
			} else {
				log.Warn("  migrate.yml drift: %s -> %s", snap.YAMLSha[:12], snap.DiskYAMLSha[:12])
			}
			if err := schema.WriteYAMLSha(ctx, d, snap.DiskYAMLSha, cli.Version); err != nil {
				return err
			}
		} else {
			log.Info("  migrate.yml unchanged")
			if _, err := d.Pool.Exec(ctx,
				`UPDATE samna_migrate.state SET tool_version = $1, updated_at = now() WHERE id = 1`,
				cli.Version); err != nil {
				return err
			}
		}
		log.Success("upgrade complete")
		return nil
	},
}

func confirmUpgrade(cfg *config.Config) error {
	if cfg.IsCI() {
		return fmt.Errorf("migrate upgrade is local only and refuses to run in CI (set neither CI nor GITHUB_ACTIONS env var)")
	}
	if assumeYes {
		return nil
	}
	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 {
		return fmt.Errorf("migrate upgrade requires an interactive tty; use --yes to bypass")
	}
	host := cfg.PGHost
	if host == "" {
		host = "localhost"
	}
	fmt.Printf("\nmigrate upgrade is sensitive.\n  database: %s@%s\n  user:     %s\n\nType %s to confirm: ",
		cfg.PGDatabase, host, cfg.PGUser, cfg.PGDatabase)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return err
	}
	if strings.TrimSpace(line) != cfg.PGDatabase {
		return fmt.Errorf("confirmation mismatch; aborting")
	}
	return nil
}

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
	Short: "Walk the samna_migrate schema chain and reconcile state.",
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
		if err := confirmDatabase(cfg, "migrate upgrade"); err != nil {
			return err
		}
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		if force {
			if err := schema.Ensure(ctx, d); err != nil {
				return err
			}
			if _, err := d.Pool.Exec(ctx, `UPDATE samna_migrate.state SET schema_version = 0 WHERE id = 1`); err != nil {
				return err
			}
			log.Warn("--force: reset schema_version to 0")
		}
		log.Header("migrate upgrade")
		if err := upgrade.Apply(ctx, d, stepsFile, cli.Version, true); err != nil {
			return err
		}
		log.Success("upgrade complete")
		return nil
	},
}

func confirmDatabase(cfg *config.Config, action string) error {
	if assumeYes {
		return nil
	}
	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 {
		return fmt.Errorf("%s requires an interactive tty; use --yes to bypass", action)
	}
	host := cfg.PGHost
	if host == "" {
		host = "localhost"
	}
	fmt.Printf("\n%s is sensitive.\n  database: %s@%s\n  user:     %s\n\nType %s to confirm: ",
		action, cfg.PGDatabase, host, cfg.PGUser, cfg.PGDatabase)
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

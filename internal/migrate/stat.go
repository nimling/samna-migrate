package migrate

import (
	"context"
	"fmt"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var statCmd = &cobra.Command{
	Use:   "stat",
	Short: "Show samna_migrate.state and recent history",
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
		if err := schema.Ensure(ctx, d); err != nil {
			return err
		}
		sv, _ := schema.GetSchemaVersion(ctx, d)
		tv, _ := schema.GetToolVersion(ctx, d)
		yaml, _ := schema.GetYAMLSha(ctx, d)
		log.Header(fmt.Sprintf("migrate stat: %s@%s", cfg.PGDatabase, cfg.PGHost))
		log.Plain("  this tool:     %s (schema %d)", cli.Version, cli.SchemaVersion)
		log.Plain("  db tool:       %s (schema %d)", tv, sv)
		if yaml == "" {
			log.Plain("  yaml sha:      <unset>")
		} else {
			log.Plain("  yaml sha:      %s", yaml[:12])
		}
		showCounts(ctx, d)
		return nil
	},
}

func showCounts(ctx context.Context, d *db.DB) {
	rows, err := d.Pool.Query(ctx, `
		SELECT step_type, state, COUNT(*)
		FROM samna_migrate.file
		GROUP BY step_type, state
		ORDER BY step_type, state`)
	if err != nil {
		return
	}
	defer rows.Close()
	fmt.Println("  file counts:")
	for rows.Next() {
		var t, s string
		var c int
		rows.Scan(&t, &s, &c)
		fmt.Printf("    %-12s %-10s %d\n", t, s, c)
	}
}

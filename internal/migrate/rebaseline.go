package migrate

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/hash"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var rebaselineReason string

var rebaselineCmd = &cobra.Command{
	Use:   "rebaseline <file_path>...",
	Short: "Accept the on disk content of applied files as the new checksum, with an audited reason",
	Long: `For each given file_path, updates samna_migrate.file to the sha256 of the
file on disk and writes a history row with action_type rebaseline carrying
the prior sha, the new sha, and the required --reason. This is the supported
way to bless an intentional edit to an applied file. Hand rolled UPDATE
statements against samna_migrate leave no audit trail; this does.

Refreshes ` + lock.FileName + ` when it exists.`,
	Args: cobra.MinimumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if strings.TrimSpace(rebaselineReason) == "" {
			return fmt.Errorf("--reason is required")
		}
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
		if err := confirmRebaseline(cfg, args); err != nil {
			return err
		}

		host := cfg.PGHost
		if host == "" {
			host = "localhost"
		}

		for _, fp := range args {
			abs := dbDir + "/" + fp
			diskSha, err := hash.File(abs)
			if err != nil {
				return fmt.Errorf("read %s: %w", fp, err)
			}
			size, _ := hash.Size(abs)

			var id int
			var dbSha, state string
			var appliedAt *time.Time
			err = d.Pool.QueryRow(ctx,
				`SELECT id, sha256, state, applied_at FROM samna_migrate.file WHERE file_path = $1`, fp).
				Scan(&id, &dbSha, &state, &appliedAt)
			if err != nil {
				return fmt.Errorf("%s is not in samna_migrate.file: %w", fp, err)
			}
			if dbSha == diskSha && state == "applied" {
				log.Info("  %s already at disk sha and applied, skipping", fp)
				continue
			}

			if state == "pending" && appliedAt != nil {
				_, err = d.Pool.Exec(ctx, `
					UPDATE samna_migrate.file
					SET state = 'applied', state_changed_at = now(), updated_at = now()
					WHERE id = $1`, id)
				if err != nil {
					return err
				}
				log.Info("  %s restored to applied, replay cancelled", fp)
			}

			if dbSha != diskSha {
				err = d.ExecUpgrade(ctx, `
					UPDATE samna_migrate.file
					SET sha256 = $1, size_bytes = $2, updated_at = now()
					WHERE id = $3`, diskSha, size, id)
				if err != nil {
					return err
				}
			}

			notes := fmt.Sprintf("prior=%s new=%s reason=%s", dbSha, diskSha, rebaselineReason)
			_, err = d.Pool.Exec(ctx, `
				INSERT INTO samna_migrate.history (file_id, step_name, file_path, file_name, sha256,
				                                    action_type, tool_version, executed_by, host, database,
				                                    duration_ms, success, started_at, ended_at, notes)
				VALUES ($1, 'rebaseline', $2, $3, $4, 'rebaseline', $5, $6, $7, $8, 0, true, now(), now(), $9)`,
				id, fp, baseName(fp), diskSha, cli.Version, cfg.PGUser, host, cfg.PGDatabase, notes)
			if err != nil {
				return err
			}
			log.Success("  %s rebaselined %s to %s", fp, dbSha[:12], diskSha[:12])
		}

		refreshed, err := lock.RefreshIfPresent(ctx, d, dbDir, cfg.PGDatabase, cli.Version)
		if err != nil {
			return err
		}
		if refreshed {
			log.Info("refreshed %s", lock.Path(dbDir))
		}
		return nil
	},
}

func confirmRebaseline(cfg *config.Config, files []string) error {
	if assumeYes {
		return nil
	}
	fi, _ := os.Stdin.Stat()
	if (fi.Mode() & os.ModeCharDevice) == 0 {
		return fmt.Errorf("rebaseline requires an interactive tty; use --yes to bypass")
	}
	host := cfg.PGHost
	if host == "" {
		host = "localhost"
	}
	fmt.Printf("\nrebaseline accepts edited applied files as truth.\n  database: %s@%s\n  files:    %s\n\nType %s to confirm: ",
		cfg.PGDatabase, host, strings.Join(files, ", "), cfg.PGDatabase)
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

func baseName(fp string) string {
	if i := strings.LastIndex(fp, "/"); i >= 0 {
		return fp[i+1:]
	}
	return fp
}

func init() {
	rebaselineCmd.Flags().StringVar(&rebaselineReason, "reason", "", "Why the applied file was edited, recorded in history")
	rootCmd.AddCommand(rebaselineCmd)
}

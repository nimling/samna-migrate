package migrate

import (
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var lockCmd = &cobra.Command{
	Use:   "lock",
	Short: "Write the applied file ledger to " + lock.FileName,
	Long: `Captures file_path and sha256 for every applied row in samna_migrate.file
into ` + lock.FileName + ` inside the database directory. Commit the file.
smig lint then rejects any edit to a locked file, which catches checksum
drift at the keystroke instead of at the deploy. smig up, smig rebaseline,
and smig merge --apply refresh the lockfile automatically when it exists.`,
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
		if err := bootCheck(ctx, d, stepsFile, cli.Version); err != nil {
			return err
		}
		entries, err := lock.Collect(ctx, d)
		if err != nil {
			return err
		}
		path := lock.Path(dbDir)
		if err := lock.Write(path, cfg.PGDatabase, cli.Version, entries); err != nil {
			return err
		}
		log.Success("wrote %s with %d applied files", path, len(entries))
		return nil
	},
}

func init() {
	rootCmd.AddCommand(lockCmd)
}

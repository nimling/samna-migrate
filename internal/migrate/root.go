package migrate

import (
	"os"

	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	stepsFile        string
	dbDir            string
	envFile          string
	assumeYes        bool
	force            bool
	silent           bool
	verboseCount     int
	extremelyVerbose bool
)

func envDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

const banner = "\n" +
	"   ▄████████   ▄▄▄▄███▄▄▄▄    ▄█     ▄██████▄  \n" +
	"  ███    ███ ▄██▀▀▀███▀▀▀██▄ ███    ███    ███ \n" +
	"  ███    █▀  ███   ███   ███ ███▌   ███    █▀  \n" +
	"  ███        ███   ███   ███ ███▌  ▄███        \n" +
	"▀███████████ ███   ███   ███ ███▌ ▀▀███ ████▄  \n" +
	"         ███ ███   ███   ███ ███    ███    ███ \n" +
	"   ▄█    ███ ███   ███   ███ ███    ███    ███ \n" +
	" ▄████████▀   ▀█   ███   █▀  █▀     ████████▀  \n"

var rootCmd = &cobra.Command{
	Use:     "smig",
	Short:   "Database migration tool with upgrade-gated CI deploys",
	Long:    banner + "\nsmig runs structured database migrations defined in a yaml step file, with sha-locked apply history, optional position-based ordering, and a strict boot_check that gates CI behind operator-acknowledged local upgrades.",
	Version: cli.Version,
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		switch {
		case silent:
			log.Level = log.LevelSilent
		case extremelyVerbose || verboseCount >= 2:
			log.Level = log.LevelExtreme
		case verboseCount == 1:
			log.Level = log.LevelVerbose
		default:
			log.Level = log.LevelNormal
		}
	},
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.PersistentFlags().StringVar(&stepsFile, "schema", envDefault("MIGRATE_SCHEMA", "./database/migrate.yml"), "Path to migrate.yml, defaults from MIGRATE_SCHEMA")
	rootCmd.PersistentFlags().StringVar(&dbDir, "db-dir", envDefault("DB_DIR", "./database"), "Path to database directory, defaults from DB_DIR")
	rootCmd.PersistentFlags().StringVar(&envFile, "env", "", "Optional dotenv file to load")
	rootCmd.PersistentFlags().BoolVarP(&assumeYes, "yes", "y", false, "Bypass interactive confirmation prompts")
	rootCmd.PersistentFlags().BoolVar(&force, "force", false, "Bypass safety checks where supported")
	rootCmd.PersistentFlags().BoolVarP(&silent, "silent", "s", false, "Suppress all output except errors")
	rootCmd.PersistentFlags().CountVarP(&verboseCount, "verbose", "v", "Verbose output, repeat as -vv for extreme")
	rootCmd.PersistentFlags().BoolVar(&extremelyVerbose, "extremely-verbose", false, "Dump every SQL statement and all psql output")
	rootCmd.PersistentFlags().StringVar(&cli.AnthropicKey, "anthropic-key", "", "Anthropic API key (or set ANTHROPIC_API_KEY)")
	rootCmd.PersistentFlags().StringVar(&cli.Model, "model", "claude-sonnet-4-6", "Claude model id for AI commands")

	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(upgradeCmd)
	rootCmd.AddCommand(statCmd)
	rootCmd.AddCommand(checkCmd)
}

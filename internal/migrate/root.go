package migrate

import (
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var (
	stepsFile string
	dbDir     string
	envFile   string
	assumeYes bool
	force     bool
)

var rootCmd = &cobra.Command{
	Use:     "smig",
	Short:   "Database migration tool with upgrade-gated CI deploys",
	Long:    "smig runs structured database migrations defined in a yaml step file, with sha-locked apply history, optional position-based ordering, and a strict boot_check that gates CI behind operator-acknowledged local upgrades.",
	Version: cli.Version,
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.PersistentFlags().StringVar(&stepsFile, "schema", "./database/migrate.yml", "Path to migrate.yml")
	rootCmd.PersistentFlags().StringVar(&dbDir, "db-dir", "./database", "Path to database directory")
	rootCmd.PersistentFlags().StringVar(&envFile, "env", "", "Optional dotenv file to load")
	rootCmd.PersistentFlags().BoolVarP(&assumeYes, "yes", "y", false, "Bypass interactive confirmation prompts")
	rootCmd.PersistentFlags().BoolVar(&force, "force", false, "Bypass safety checks where supported")
	rootCmd.PersistentFlags().StringVar(&cli.AnthropicKey, "anthropic-key", "", "Anthropic API key (or set ANTHROPIC_API_KEY)")
	rootCmd.PersistentFlags().StringVar(&cli.Model, "model", "claude-sonnet-4-6", "Claude model id for AI commands")

	rootCmd.AddCommand(upCmd)
	rootCmd.AddCommand(upgradeCmd)
	rootCmd.AddCommand(statCmd)
	rootCmd.AddCommand(checkCmd)
}

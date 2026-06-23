package migrate

import (
	"fmt"
	"os"
	"strings"
	"time"

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
	Use:           "smig",
	Short:         "Database migration tool with upgrade-gated CI deploys",
	Long:          "smig runs structured database migrations defined in a yaml step file, with sha-locked apply history, optional position-based ordering, and a strict boot_check that gates CI behind operator-acknowledged local upgrades.",
	Version:       cli.Version,
	SilenceUsage:  true,
	SilenceErrors: true,
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

func stdoutTTY() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

func showBanner() {
	lines := strings.Split(strings.Trim(banner, "\n"), "\n")
	if !stdoutTTY() {
		fmt.Println(strings.Join(lines, "\n"))
		return
	}
	fmt.Print("\033[?25l")
	for _, ln := range lines {
		fmt.Printf("\033[36m%s\033[0m\n", ln)
	}
	for s := 0; s < len(lines); s++ {
		fmt.Printf("\033[%dA", len(lines))
		for i, ln := range lines {
			if i == s {
				fmt.Printf("\033[1;37m%s\033[0m\n", ln)
			} else {
				fmt.Printf("\033[36m%s\033[0m\n", ln)
			}
		}
		time.Sleep(40 * time.Millisecond)
	}
	fmt.Printf("\033[%dA", len(lines))
	for _, ln := range lines {
		fmt.Printf("\033[1;36m%s\033[0m\n", ln)
	}
	fmt.Print("\033[?25h")
}

func init() {
	defaultHelp := rootCmd.HelpFunc()
	rootCmd.SetHelpFunc(func(c *cobra.Command, args []string) {
		if c == rootCmd {
			showBanner()
		}
		defaultHelp(c, args)
	})

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

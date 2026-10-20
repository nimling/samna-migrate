package migrate

import (
	nimcli "github.com/nimling/nimbody/cli"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

type versionInfo struct {
	Version       string `json:"version"`
	SchemaVersion int    `json:"schema_version"`
	GitCommit     string `json:"git_commit"`
	BuildTime     string `json:"build_time"`
}

var versionCmd = &cobra.Command{
	Use:     "version",
	Short:   "Print the smig build and the samna_migrate schema version it carries",
	Example: "  smig version --json",
	Args:    cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		out := cmd.OutOrStdout()
		info := versionInfo{Version: cli.Version, SchemaVersion: cli.SchemaVersion, GitCommit: cli.GitCommit, BuildTime: cli.BuildTime}
		return nimcli.PrintValue(out, info, nimcli.FormatFor(out, jsonOutput))
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}

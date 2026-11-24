package migrate

import (
	nimcli "github.com/nimling/nimbody/cli"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func init() {
	rootCmd.AddCommand(nimcli.PluginCommand(nimcli.Plugin{
		Name:        "smig",
		Owner:       "nimling",
		Description: "Run, reconcile and fold database migrations from any repo: the smig and smig-reconcile skills and an mcp server exposing every command as a tool.",
		Tree:        skillTree,
		Version:     func() string { return cli.Version },
	}))
}

package migrate

import (
	nimcli "github.com/nimling/nimbody/cli"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func init() {
	rootCmd.AddCommand(nimcli.PluginCommand(nimcli.Plugin{
		Name:        "smig",
		Owner:       "nimling",
		Description: rootCmd.Short,
		Skill:       skillDocument,
		Version:     func() string { return cli.Version },
	}))
}

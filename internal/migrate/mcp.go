package migrate

import (
	nimcli "github.com/nimling/nimbody/cli"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func init() {
	rootCmd.AddCommand(nimcli.MCPCommand(rootCmd, "smig", func() string { return cli.Version }))
}

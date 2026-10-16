package migrate

import (
	"context"
	"io"
	"os"

	"github.com/nimling/nimbody/mcp"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var outsideMCP = map[string]bool{
	"mcp":        true,
	"skill":      true,
	"completion": true,
	"help":       true,
	"version":    true,
}

var mcpCmd = &cobra.Command{
	Use:   "mcp",
	Short: "Serve every command as a tool over the model context protocol on stdio",
	Long: `Serve every command as a tool over the model context protocol on stdio. A tool runs this binary with
the arguments and flags it is given, so it reads the same environment and --env file as a terminal in the
directory claude was started in. Each applied file is a step a host that renders MCP Apps shows live on
the run page.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		return ServeMCP(cmd.Context(), cmd.InOrStdin(), cmd.OutOrStdout())
	},
}

func mcpTools(root *cobra.Command, executable string) []mcp.Tool {
	var tools []mcp.Tool
	var walk func(cmd *cobra.Command, path []string)
	walk = func(cmd *cobra.Command, path []string) {
		if cmd.Hidden || (len(path) > 0 && outsideMCP[path[0]]) {
			return
		}
		if cmd.HasAvailableSubCommands() {
			for _, child := range cmd.Commands() {
				if child.IsAvailableCommand() {
					walk(child, append(append([]string{}, path...), child.Name()))
				}
			}
			return
		}
		if !cmd.Runnable() || len(path) == 0 {
			return
		}
		var flags []mcp.Flag
		add := func(flag *pflag.Flag) {
			if flag.Hidden || flag.Name == "help" || flag.Name == "version" {
				return
			}
			flags = append(flags, mcp.Flag{Name: flag.Name, Kind: flag.Value.Type(), Usage: flag.Usage})
		}
		cmd.LocalFlags().VisitAll(add)
		cmd.InheritedFlags().VisitAll(add)
		tools = append(tools, mcp.Command(executable, path, cmd.CommandPath()+": "+cmd.Short+"\nusage: "+cmd.UseLine(), flags))
	}
	walk(root, nil)
	return tools
}

func ServeMCP(ctx context.Context, in io.Reader, out io.Writer) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	server := &mcp.Server{Name: "smig", Version: cli.Version, Tools: mcpTools(rootCmd, executable)}
	return server.Serve(ctx, in, out)
}

func init() {
	rootCmd.AddCommand(mcpCmd)
}

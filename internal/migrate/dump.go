package migrate

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/reconcile"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/spf13/cobra"
)

var (
	dumpAll    bool
	dumpTables []string
	dumpOut    string
)

var dumpCmd = &cobra.Command{
	Use:   "dump",
	Short: "Dump table data to JSON, one file per table",
	Long: `Writes the rows of each selected table to <schema>.<table>.json in the output
directory. Tables are limited to the base tables in the schemas declared by
migrate.yml.

With --all every such table is dumped. With --table=<schema.table>, repeatable and
comma joined, a subset is dumped. With neither, an interactive list lets you pick
tables with the arrow keys and space, then asks for the output path.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			if err := config.LoadDotEnv(envFile); err != nil {
				return err
			}
		}
		cfg := config.FromEnv()
		cfg.StepsFile = stepsFile
		cfg.DBDir = dbDir
		d, err := db.Open(ctx, cfg)
		if err != nil {
			return err
		}
		defer d.Close()
		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}
		available, err := data.Tables(ctx, d, reconcile.SchemaUnion(stepsCfg))
		if err != nil {
			return err
		}

		selected, out, err := selectDumpTargets(available)
		if err != nil {
			return err
		}
		if len(selected) == 0 {
			log.Info("nothing selected")
			return nil
		}

		log.Header(fmt.Sprintf("dump %d table(s) to %s", len(selected), out))
		for _, t := range selected {
			count, path, err := data.DumpTable(ctx, d, t, out)
			if err != nil {
				return fmt.Errorf("dump %s: %w", t.Qualified(), err)
			}
			log.Success("  %s  %d row(s) -> %s", t.Qualified(), count, path)
		}
		return nil
	},
}

func selectDumpTargets(available []data.Table) ([]data.Table, string, error) {
	if dumpAll {
		return available, dumpOut, nil
	}
	if len(dumpTables) > 0 {
		selected, err := resolveTables(available, dumpTables)
		return selected, dumpOut, err
	}
	if len(available) == 0 {
		return nil, "", fmt.Errorf("no tables in the declared schemas")
	}
	selected, err := pickTables(available)
	if err != nil {
		return nil, "", err
	}
	out := dumpOut
	if !dumpOutChanged {
		out = promptPath()
	}
	return selected, out, nil
}

func resolveTables(available []data.Table, requested []string) ([]data.Table, error) {
	set := map[string]data.Table{}
	for _, t := range available {
		set[t.Qualified()] = t
	}
	out := []data.Table{}
	for _, raw := range requested {
		for _, name := range strings.Split(raw, ",") {
			name = strings.TrimSpace(name)
			if name == "" {
				continue
			}
			t, ok := set[name]
			if !ok {
				return nil, fmt.Errorf("%s is not a table in the declared schemas", name)
			}
			out = append(out, t)
		}
	}
	return out, nil
}

func promptPath() string {
	if !stdinTTY() {
		return "."
	}
	fmt.Print("output directory [.]: ")
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "."
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return "."
	}
	return line
}

func pickTables(tables []data.Table) ([]data.Table, error) {
	if !stdinTTY() || !stdoutTTY() {
		return nil, fmt.Errorf("no --all or --table given and no interactive tty")
	}
	restore := cbreak()
	if restore == nil {
		return nil, fmt.Errorf("cannot enter raw mode for selection")
	}
	defer restore()
	fmt.Print("\033[?25l")
	defer fmt.Print("\033[?25h")

	checked := make([]bool, len(tables))
	cursor := 0
	draw := func(first bool) {
		if !first {
			fmt.Printf("\033[%dA", len(tables)+1)
		}
		fmt.Print("\r\033[K\033[90mspace toggles, a all, enter confirms, q aborts\033[0m\n")
		for i, t := range tables {
			mark := " "
			if checked[i] {
				mark = "x"
			}
			pointer := "  "
			if i == cursor {
				pointer = "\033[36m> "
			}
			fmt.Printf("\r\033[K%s[%s] %s\033[0m\n", pointer, mark, t.Qualified())
		}
	}
	draw(true)

	var b [1]byte
	for {
		n, err := os.Stdin.Read(b[:])
		if err != nil || n == 0 {
			return nil, fmt.Errorf("input closed")
		}
		switch b[0] {
		case 0x03, 'q', 'Q':
			return nil, fmt.Errorf("aborted")
		case '\r', '\n':
			out := []data.Table{}
			for i, t := range tables {
				if checked[i] {
					out = append(out, t)
				}
			}
			if len(out) == 0 {
				continue
			}
			return out, nil
		case ' ':
			checked[cursor] = !checked[cursor]
			draw(false)
		case 'a', 'A':
			all := true
			for _, c := range checked {
				if !c {
					all = false
					break
				}
			}
			for i := range checked {
				checked[i] = !all
			}
			draw(false)
		case 'k':
			if cursor > 0 {
				cursor--
				draw(false)
			}
		case 'j':
			if cursor < len(tables)-1 {
				cursor++
				draw(false)
			}
		case 0x1b:
			var seq [2]byte
			if _, err := os.Stdin.Read(seq[:1]); err != nil || seq[0] != '[' {
				continue
			}
			if _, err := os.Stdin.Read(seq[1:2]); err != nil {
				continue
			}
			switch seq[1] {
			case 'A':
				if cursor > 0 {
					cursor--
					draw(false)
				}
			case 'B':
				if cursor < len(tables)-1 {
					cursor++
					draw(false)
				}
			}
		}
	}
}

var dumpOutChanged bool

func init() {
	dumpCmd.Flags().BoolVar(&dumpAll, "all", false, "Dump every table in the declared schemas")
	dumpCmd.Flags().StringSliceVar(&dumpTables, "table", nil, "Table to dump as schema.table, repeatable and comma joined")
	dumpCmd.Flags().StringVar(&dumpOut, "out", ".", "Directory to write the json files into")
	dumpCmd.PreRun = func(cmd *cobra.Command, args []string) {
		dumpOutChanged = cmd.Flags().Changed("out")
	}
	rootCmd.AddCommand(dumpCmd)
}

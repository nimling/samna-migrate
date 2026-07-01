package migrate

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/spf13/cobra"
)

var (
	insertPaths      []string
	insertNoTriggers bool
)

var insertCmd = &cobra.Command{
	Use:   "insert [path...]",
	Short: "Insert rows from <schema>.<table>.json files back into their tables",
	Long: `Loads each json file produced by dump back into the table named by its filename.
Point it at a folder, which loads every json file inside, or at individual files.
Paths are taken from positional arguments and repeated --path flags; with none the
current directory is used.

Each file is loaded in its own transaction via jsonb_populate_recordset, typing every
column from the target table. --no-triggers disables user triggers on the table for
the duration of the load.`,
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

		inputs := append([]string{}, args...)
		inputs = append(inputs, insertPaths...)
		if len(inputs) == 0 {
			inputs = []string{"."}
		}
		files, err := collectJSON(inputs)
		if err != nil {
			return err
		}
		if len(files) == 0 {
			log.Info("no json files found")
			return nil
		}

		log.Header(fmt.Sprintf("insert %d file(s) into %s", len(files), cfg.PGDatabase))
		for _, f := range files {
			t, ok := tableFromFile(f)
			if !ok {
				return fmt.Errorf("%s is not named <schema>.<table>.json", f)
			}
			exists, err := data.TableExists(ctx, d, t)
			if err != nil {
				return err
			}
			if !exists {
				return fmt.Errorf("%s: table %s does not exist", f, t.Qualified())
			}
			rows, err := data.InsertFile(ctx, d, t, f, insertNoTriggers)
			if err != nil {
				return err
			}
			log.Success("  %s <- %s  %d row(s)", t.Qualified(), filepath.Base(f), rows)
		}
		return nil
	},
}

func collectJSON(inputs []string) ([]string, error) {
	out := []string{}
	seen := map[string]bool{}
	add := func(p string) {
		if seen[p] {
			return
		}
		seen[p] = true
		out = append(out, p)
	}
	for _, in := range inputs {
		info, err := os.Stat(in)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			add(in)
			continue
		}
		entries, err := os.ReadDir(in)
		if err != nil {
			return nil, err
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
				continue
			}
			add(filepath.Join(in, e.Name()))
		}
	}
	return out, nil
}

func tableFromFile(path string) (data.Table, bool) {
	base := filepath.Base(path)
	if !strings.HasSuffix(base, ".json") {
		return data.Table{}, false
	}
	return data.ParseTable(strings.TrimSuffix(base, ".json"))
}

func init() {
	insertCmd.Flags().StringSliceVar(&insertPaths, "path", nil, "Folder or file to load, repeatable and comma joined")
	insertCmd.Flags().BoolVar(&insertNoTriggers, "no-triggers", false, "Disable user triggers on each table during the load")
	rootCmd.AddCommand(insertCmd)
}

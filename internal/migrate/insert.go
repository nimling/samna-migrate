package migrate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	nimcli "github.com/nimling/nimbody/cli"
	"github.com/nimling/nimbody/respond"
	"github.com/nimling/nimbody/stream"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/spf13/cobra"
)

var (
	insertPaths      []string
	insertNoTriggers bool
	insertMode       string
	insertPlan       bool
	insertUpdatedAt  string
)

var insertCmd = &cobra.Command{
	Use:   "insert [path...]",
	Short: "Load rows from <schema>.<table> json, jsonl, csv or sql files into their tables, inserting, updating or skipping by primary key",
	Long: `Loads each file produced by dump back into the table named by its filename.
Point it at a folder, which loads every json, jsonl, ndjson, csv and sql file inside,
or at individual files. Paths are taken from positional arguments and repeated --path
flags; with none the current directory is used. Every file is checked for its table
before the first one loads.

The format is read from the extension: .json is a json array (or one object per
line), .jsonl and .ndjson one object per line, .csv a header of column names then
rows, .sql statements. Rows stream into a temporary stage in batches, typed from the
target table, then reach the table in one statement per step. Each file loads in its
own transaction.

--mode says what a row whose primary key already exists does, read from the catalog:
  insert   (default) every row is inserted; a row that exists refuses the file
  create   a new row is inserted, one that exists and is the same is skipped, one
           that exists and differs refuses the file
  upsert   a new row is inserted, one that exists is updated with every column the
           file carries, one that is the same is skipped
  merge    as upsert, but each row updates only the columns its own object carries,
           so sa_owner_id, sa_created_by and the other columns it lacks stay
  skip     a new row is inserted, one that exists is left as it is
  latest   as upsert, but a row is updated only when its update time is later than
           the stored one: sa_updated_at, else updated_at, or --updated-at=<column>
  replace  as upsert, then every row of the table the file lacks is deleted; a file
           with no rows deletes nothing
Every mode but insert needs a primary key. A row the table already holds as it is is
never written, so triggers do not fire for it. A .sql file runs its own statements in
its transaction and --mode does not apply to it.

--plan prints per file how many rows would be inserted, updated, skipped, deleted
and refused, and writes nothing; for a .sql file the statements and the tables they
touch. --json prints the same as json. --no-triggers disables user triggers on the
table for the load.`,
	Example: `  smig insert ./snapshot --mode=merge --plan --env=.env.tst
  smig insert ./snapshot/public.person.jsonl --mode=upsert --env=.env.tst
  smig insert ./snapshot --mode=skip --json`,
	Args:        cobra.ArbitraryArgs,
	Annotations: map[string]string{"mcp": "destructive"},
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if !data.ValidMode(insertMode) {
			return nimcli.Rejected(fmt.Sprintf("--mode is %s, not %s", strings.Join(data.Modes, ", "), insertMode), "Run 'smig insert --help' for what each mode does.")
		}
		inputs := append([]string{}, args...)
		inputs = append(inputs, insertPaths...)
		if len(inputs) == 0 {
			inputs = []string{"."}
		}
		files, err := collectFiles(inputs)
		if err != nil {
			return err
		}
		if len(files) == 0 {
			log.Info("no json, jsonl, csv or sql files found")
			return nil
		}
		tables := make([]data.Table, len(files))
		held := map[string]string{}
		for i, f := range files {
			t, ok := tableFromFile(f)
			if !ok {
				return nimcli.Rejected(fmt.Sprintf("%s is not named <schema>.<table>.<json|jsonl|ndjson|csv|sql>", f), "")
			}
			tables[i] = t
			if format, _ := data.GetFormat(f); insertMode == data.ModeReplace && format != data.FormatSQL {
				if other, ok := held[t.Qualified()]; ok {
					return nimcli.Rejected(fmt.Sprintf("mode replace deletes what each file lacks, and %s and %s both load %s", other, f, t.Qualified()), "Load one file per table with replace, or use upsert.")
				}
				held[t.Qualified()] = f
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
		for i, t := range tables {
			exists, err := data.TableExists(ctx, d, t)
			if err != nil {
				return err
			}
			if !exists {
				return nimcli.Rejected(fmt.Sprintf("%s: table %s does not exist", files[i], t.Qualified()), "")
			}
		}

		if jsonOutput {
			log.Level = log.LevelSilent
		}
		header := fmt.Sprintf("insert %d file(s) into %s, mode %s", len(files), cfg.PGDatabase, insertMode)
		if insertPlan {
			header = fmt.Sprintf("insert plan for %d file(s) into %s, mode %s, nothing written", len(files), cfg.PGDatabase, insertMode)
		}
		log.Header(header)
		results := []data.Result{}
		for i, f := range files {
			if format, _ := data.GetFormat(f); format == data.FormatSQL && cmd.Flags().Changed("mode") {
				log.Warn("  %s carries its own statements, --mode does not apply to it", filepath.Base(f))
			}
			r, err := insertOne(ctx, d, tables[i], f)
			if err != nil {
				if message, hint, ok := data.GetRefusal(err); ok {
					return nimcli.Refused(message, hint)
				}
				return err
			}
			results = append(results, r)
			line := fmt.Sprintf("  %s <- %s  %s", r.Table, filepath.Base(f), insertCounts(r))
			if insertPlan {
				log.Plain("%s", line)
			} else {
				log.Success("%s", line)
			}
			if len(r.Ignored) > 0 {
				log.Warn("    the file carries %s, which %s lacks, ignored", strings.Join(r.Ignored, ", "), r.Table)
			}
		}
		if jsonOutput {
			return nimcli.PrintValue(cmd.OutOrStdout(), results, nimcli.FormatJSON)
		}
		return nil
	},
}

func insertOne(ctx context.Context, d *db.DB, t data.Table, f string) (data.Result, error) {
	start := time.Now()
	label := "Insert " + filepath.Base(f)
	if insertPlan {
		label = "Plan " + filepath.Base(f)
	}
	terminal := !jsonOutput && log.Level != log.LevelSilent && nimcli.Terminal(os.Stderr) && !stream.Machine()
	var last time.Time
	progress := func(rows, bytes int64) {
		now := time.Now()
		if now.Sub(last) < 250*time.Millisecond {
			return
		}
		last = now
		switch {
		case stream.Machine():
			insertReport(respond.Step{ID: f, Label: label, Status: "running", StartedAt: start.UTC(), Data: insertProgress(rows, bytes)})
		case terminal:
			fmt.Fprintf(os.Stderr, "\r\033[K  %s  %s", filepath.Base(f), insertProgress(rows, bytes))
		}
	}
	if stream.Machine() {
		insertReport(respond.Step{ID: f, Label: label, Status: "running", StartedAt: start.UTC()})
	}
	r, err := data.InsertFile(ctx, d, t, f, data.Options{
		Mode:       insertMode,
		UpdatedAt:  insertUpdatedAt,
		Plan:       insertPlan,
		NoTriggers: insertNoTriggers,
		Progress:   progress,
	})
	if terminal && !last.IsZero() {
		fmt.Fprint(os.Stderr, "\r\033[K")
	}
	if stream.Machine() {
		ended := time.Now().UTC()
		step := respond.Step{ID: f, Label: label, Status: "done", StartedAt: start.UTC(), EndedAt: &ended, Data: r}
		if err != nil {
			step.Status = "failed"
			step.Error = err.Error()
		}
		insertReport(step)
	}
	return r, err
}

func insertProgress(rows, bytes int64) string {
	size := fmt.Sprintf("%.1f MiB", float64(bytes)/(1<<20))
	switch {
	case rows < 0:
		return size + " read"
	case bytes == 0:
		return fmt.Sprintf("%d statement(s)", rows)
	default:
		return fmt.Sprintf("%d row(s), %s read", rows, size)
	}
}

func insertCounts(r data.Result) string {
	if r.Format == data.FormatSQL {
		touched := "no table named"
		if len(r.Tables) > 0 {
			touched = strings.Join(r.Tables, ", ")
		}
		if r.Plan {
			return fmt.Sprintf("%d statement(s) on %s", r.Statements, touched)
		}
		return fmt.Sprintf("%d statement(s) on %s, %d row(s) written", r.Statements, touched, r.Rows)
	}
	verbs := []string{"inserted", "updated", "skipped", "deleted", "refused"}
	if r.Plan {
		verbs = []string{"insert", "update", "skip", "delete", "refuse"}
	}
	counts := []int64{r.Inserted, r.Updated, r.Skipped, r.Deleted, r.Refused}
	parts := []string{}
	for i, n := range counts {
		if n > 0 || i < 3 {
			parts = append(parts, fmt.Sprintf("%d %s", n, verbs[i]))
		}
	}
	return fmt.Sprintf("%d row(s): %s", r.Rows, strings.Join(parts, ", "))
}

func collectFiles(inputs []string) ([]string, error) {
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
			if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			if _, ok := data.GetFormat(e.Name()); !ok {
				continue
			}
			add(filepath.Join(in, e.Name()))
		}
	}
	return out, nil
}

func tableFromFile(path string) (data.Table, bool) {
	base := filepath.Base(path)
	if _, ok := data.GetFormat(base); !ok {
		return data.Table{}, false
	}
	return data.ParseTable(strings.TrimSuffix(base, filepath.Ext(base)))
}

func init() {
	insertCmd.Flags().StringSliceVar(&insertPaths, "path", nil, "Folder or file to load, repeatable and comma joined")
	insertCmd.Flags().BoolVar(&insertNoTriggers, "no-triggers", false, "Disable user triggers on each table during the load")
	insertCmd.Flags().StringVar(&insertMode, "mode", data.ModeInsert, "What a row whose primary key exists does: "+strings.Join(data.Modes, ", "))
	insertCmd.Flags().BoolVar(&insertPlan, "plan", false, "Print what each file would insert, update, skip, delete and refuse, and write nothing")
	insertCmd.Flags().StringVar(&insertUpdatedAt, "updated-at", "", "The update time column mode latest compares, default sa_updated_at, else updated_at")
	rootCmd.AddCommand(insertCmd)
}

var insertReport = stream.Report(os.Stderr)

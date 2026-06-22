package migrate

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/lock"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/sqlscan"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/pkg/cli"
	"github.com/spf13/cobra"
)

var upCmd = &cobra.Command{
	Use:   "up",
	Short: "Apply pending migrations after preflight",
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx := cmd.Context()
		if envFile != "" {
			if err := config.LoadDotEnv(envFile); err != nil {
				log.Warn("env: %v", err)
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
		if err := bootCheck(ctx, d, stepsFile, dbDir, cli.Version); err != nil {
			return err
		}
		stepsCfg, err := steps.Load(stepsFile)
		if err != nil {
			return err
		}
		snap, err := schema.Snapshot(ctx, d, stepsFile)
		if err != nil {
			return err
		}

		log.Header(fmt.Sprintf("migrate up: %s", cfg.PGDatabase))
		report, err := preflight.Scan(ctx, d, snap, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		if report.YAMLDrift {
			log.Detail("yaml drift: db %s disk %s", shortSha(report.YAMLDBSha), shortSha(report.YAMLDiskSha))
		}
		log.Detail("preflight: %d new, %d unchanged, %d drift, %d rebased, %d missing",
			report.FilesNew, report.FilesUnchanged, report.FilesDrift, report.FilesRebased, report.FilesMissing)

		pendings, err := apply.ListPending(ctx, d)
		if err != nil {
			return err
		}
		if len(pendings) == 0 {
			log.Success("nothing pending")
			return nil
		}
		log.Detail("%d pending file(s)", len(pendings))

		executedBy := cfg.PGUser
		host := cfg.PGHost
		if host == "" {
			host = "localhost"
		}
		hostName, _ := os.Hostname()
		_ = hostName

		groups := groupPending(pendings)
		width := 0
		for _, g := range groups {
			if len(g.name) > width {
				width = len(g.name)
			}
		}

		applied := 0
		start := time.Now()
		for _, g := range groups {
			st := findStep(stepsCfg, g.name)
			log.Section(fmt.Sprintf("%-*s", width, g.name), fmt.Sprintf("%d applied", len(g.files)))
			logStepInternals(st)
			for _, p := range g.files {
				fileStart := time.Now()
				if err := apply.File(ctx, d, p, st, dbDir, cli.Version, executedBy, host, cfg.PGDatabase); err != nil {
					return fmt.Errorf("%s failed: %w", p.FilePath, err)
				}
				log.Step(p.FileName, fmt.Sprintf("  %s", time.Since(fileStart).Round(time.Millisecond)))
				log.Detail("      sha %s  size %dB  pos %d", shortSha(p.Sha), p.Size, p.Position)
				logObjects(dbDir + "/" + p.FilePath)
				applied++
			}
		}
		log.Plain("")
		log.Success("applied %d files in %s", applied, time.Since(start).Round(time.Millisecond))

		refreshed, err := lock.RefreshIfPresent(ctx, d, dbDir, cfg.PGDatabase, cli.Version)
		if err != nil {
			log.Warn("lockfile refresh: %v", err)
		} else if refreshed {
			log.Info("refreshed %s", lock.Path(dbDir))
		}
		return nil
	},
}

type pendingGroup struct {
	name  string
	files []apply.Pending
}

func groupPending(pendings []apply.Pending) []*pendingGroup {
	groups := []*pendingGroup{}
	index := map[string]*pendingGroup{}
	for _, p := range pendings {
		g := index[p.StepName]
		if g == nil {
			g = &pendingGroup{name: p.StepName}
			index[p.StepName] = g
			groups = append(groups, g)
		}
		g.files = append(g.files, p)
	}
	return groups
}

func findStep(cfg *steps.Config, name string) *steps.Step {
	for i := range cfg.Steps {
		if cfg.Steps[i].Name == name {
			return &cfg.Steps[i]
		}
	}
	return nil
}

func logStepInternals(st *steps.Step) {
	if log.Level < log.LevelVerbose || st == nil {
		return
	}
	log.Detail("      type %s  schemas %s", st.Type, strings.Join(st.Schemas, ","))
	if cond := strings.TrimSpace(st.If); cond != "" && cond != "null" {
		log.Detail("      if %s", cond)
	}
	if st.Pre != "" {
		log.Detail("      pre %s", st.Pre)
	}
	if st.Post != "" {
		log.Detail("      post %s", st.Post)
	}
	vars, err := st.ExpandVars()
	if err == nil {
		for k, v := range vars {
			log.Detail("      var %s=%s", k, v)
		}
	}
}

func shortSha(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

func logObjects(absPath string) {
	if log.Level < log.LevelVerbose {
		return
	}
	b, err := os.ReadFile(absPath)
	if err != nil {
		return
	}
	content := string(b)
	objs := sqlscan.Scan(content)
	if len(objs) == 0 {
		return
	}
	cols := []string{"kind", "name"}
	seen := map[string]bool{"kind": true, "name": true}
	for _, o := range objs {
		for _, s := range o.Stats {
			if !seen[s.Key] {
				seen[s.Key] = true
				cols = append(cols, s.Key)
			}
		}
	}
	cell := func(o sqlscan.Object, key string) string {
		switch key {
		case "kind":
			return o.Kind
		case "name":
			return o.Name
		}
		for _, s := range o.Stats {
			if s.Key == key {
				return s.Val
			}
		}
		return ""
	}
	width := make([]int, len(cols))
	for i, c := range cols {
		width[i] = len(c)
	}
	for _, o := range objs {
		for i, c := range cols {
			if v := len(cell(o, c)); v > width[i] {
				width[i] = v
			}
		}
	}
	row := func(get func(string) string) string {
		var b strings.Builder
		b.WriteString("      ")
		for i, c := range cols {
			b.WriteString(fmt.Sprintf("%-*s  ", width[i], get(c)))
		}
		return strings.TrimRight(b.String(), " ")
	}
	log.Detail("%s", row(func(c string) string { return c }))
	for _, o := range objs {
		log.Detail("%s", row(func(c string) string { return cell(o, c) }))
		if log.Level == log.LevelVerbose {
			logSQLPreview(o.SQL)
		}
	}
	if log.Level >= log.LevelExtreme {
		log.Dump("      ── %s ──", filepath.Base(absPath))
		for _, ln := range strings.Split(strings.TrimRight(content, "\n"), "\n") {
			log.Dump("        %s", ln)
		}
	}
}

const sqlPreviewLines = 8

func logSQLPreview(sql string) {
	if strings.TrimSpace(sql) == "" {
		return
	}
	lines := strings.Split(strings.TrimRight(sql, "\n"), "\n")
	limit := len(lines)
	if limit > sqlPreviewLines {
		limit = sqlPreviewLines
	}
	for i := 0; i < limit; i++ {
		log.Dim("        %s", lines[i])
	}
	if len(lines) > limit {
		log.Dim("        … +%d more lines", len(lines)-limit)
	}
}

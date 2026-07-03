package migrate

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
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

		groups, err := groupPending(pendings, stepsCfg, dbDir)
		if err != nil {
			return err
		}
		rightEdge := 0
		for _, g := range groups {
			if w := 2 + len(g.name) + 2 + len(fmt.Sprintf("%d applied", len(g.files))); w > rightEdge {
				rightEdge = w
			}
		}
		for _, p := range pendings {
			if w := 4 + len(p.FileName) + 2 + durWidth; w > rightEdge {
				rightEdge = w
			}
		}

		var objCols objColumns
		objByFile := map[string][]sqlscan.Object{}
		fileContent := map[string]string{}
		if log.Level >= log.LevelVerbose {
			objCols, objByFile, fileContent = scanObjects(pendings, dbDir)
		}

		applied := 0
		start := time.Now()
		for _, g := range groups {
			log.Section(g.name, fmt.Sprintf("%d applied", len(g.files)), rightEdge)
			logStepInternals(g.st)
			headerShown := false
			for _, p := range g.files {
				fileStart := time.Now()
				if err := apply.File(ctx, d, p, g.st, dbDir, cli.Version, executedBy, host, cfg.PGDatabase); err != nil {
					return fmt.Errorf("%s failed: %w", p.FilePath, err)
				}
				log.Step(p.FileName, time.Since(fileStart).Round(time.Millisecond).String(), rightEdge)
				log.Detail("      sha %s  size %dB  pos %d", shortSha(p.Sha), p.Size, p.Position)
				logObjects(objCols, objByFile[p.FilePath], fileContent[p.FilePath], p.FileName, &headerShown)
				applied++
			}
		}
		log.Plain("")
		log.Success("applied %d files in %s", applied, time.Since(start).Round(time.Millisecond))
		return nil
	},
}

type pendingGroup struct {
	name  string
	st    *steps.Step
	files []apply.Pending
}

func groupPending(pendings []apply.Pending, stepsCfg *steps.Config, dbDir string) ([]*pendingGroup, error) {
	groups := []*pendingGroup{}
	index := map[string]*pendingGroup{}
	for _, p := range pendings {
		st, err := apply.FileRel(stepsCfg, p.FilePath, dbDir)
		if err != nil {
			return nil, err
		}
		g := index[st.Name]
		if g == nil {
			g = &pendingGroup{name: st.Name, st: st}
			index[st.Name] = g
			groups = append(groups, g)
		}
		g.files = append(g.files, p)
	}
	stepOrder := map[string]int{}
	for i, st := range stepsCfg.Steps {
		stepOrder[st.Name] = i
	}
	sort.SliceStable(groups, func(i, j int) bool {
		return stepOrder[groups[i].name] < stepOrder[groups[j].name]
	})
	for _, g := range groups {
		sort.SliceStable(g.files, func(i, j int) bool {
			vi, _, _, oki := steps.ParseFilename(g.files[i].FileName)
			vj, _, _, okj := steps.ParseFilename(g.files[j].FileName)
			if oki && okj {
				if c := steps.CompareVersion(vi, vj); c != 0 {
					return c < 0
				}
			}
			return g.files[i].FileName < g.files[j].FileName
		})
	}
	return groups, nil
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

type objColumns struct {
	cols  []string
	width map[string]int
}

func scanObjects(pendings []apply.Pending, dbDir string) (objColumns, map[string][]sqlscan.Object, map[string]string) {
	oc := objColumns{cols: []string{"kind", "name"}, width: map[string]int{"kind": len("kind"), "name": len("name")}}
	seen := map[string]bool{"kind": true, "name": true}
	byFile := map[string][]sqlscan.Object{}
	content := map[string]string{}
	for _, p := range pendings {
		b, err := os.ReadFile(dbDir + "/" + p.FilePath)
		if err != nil {
			continue
		}
		content[p.FilePath] = string(b)
		objs := sqlscan.Scan(string(b))
		byFile[p.FilePath] = objs
		for _, o := range objs {
			if len(o.Kind) > oc.width["kind"] {
				oc.width["kind"] = len(o.Kind)
			}
			if len(o.Name) > oc.width["name"] {
				oc.width["name"] = len(o.Name)
			}
			for _, s := range o.Stats {
				if !seen[s.Key] {
					seen[s.Key] = true
					oc.cols = append(oc.cols, s.Key)
					oc.width[s.Key] = len(s.Key)
				}
				if len(s.Val) > oc.width[s.Key] {
					oc.width[s.Key] = len(s.Val)
				}
			}
		}
	}
	return oc, byFile, content
}

func logObjects(oc objColumns, objs []sqlscan.Object, content, base string, headerShown *bool) {
	if log.Level < log.LevelVerbose {
		return
	}
	if len(objs) > 0 {
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
		row := func(get func(string) string) string {
			var b strings.Builder
			b.WriteString("      ")
			for _, c := range oc.cols {
				b.WriteString(fmt.Sprintf("%-*s  ", oc.width[c], get(c)))
			}
			return strings.TrimRight(b.String(), " ")
		}
		if !*headerShown {
			log.Detail("%s", row(func(c string) string { return c }))
			*headerShown = true
		}
		for _, o := range objs {
			log.Detail("%s", row(func(c string) string { return cell(o, c) }))
			if log.Level == log.LevelVerbose {
				logSQLPreview(o.SQL)
			}
		}
	}
	if log.Level >= log.LevelExtreme {
		log.Dump("      ── %s ──", base)
		for _, ln := range strings.Split(strings.TrimRight(content, "\n"), "\n") {
			log.Dump("        %s", ln)
		}
	}
}

const sqlPreviewLines = 8

const durWidth = 8

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

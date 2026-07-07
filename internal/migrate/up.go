package migrate

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
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

var upInteractive bool

var upCmd = &cobra.Command{
	Use:   "up [target]",
	Short: "Apply pending migrations after preflight",
	Args:  cobra.MaximumNArgs(1),
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
		ordered := flatten(groups)

		target := ""
		if len(args) == 1 {
			target = args[0]
		}
		limit := len(ordered) - 1
		if upInteractive && target == "" {
			lim, tok, perr := promptTarget(os.Stdin, ordered)
			if perr != nil {
				return perr
			}
			limit, target = lim, tok
		} else if target != "" {
			lim, rerr := resolveTarget(target, ordered)
			if rerr != nil {
				return rerr
			}
			limit = lim
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
		var cur *pendingGroup
		headerShown := false
		for i := 0; i <= limit; i++ {
			o := ordered[i]
			if o.g != cur {
				cur = o.g
				log.Section(o.g.name, fmt.Sprintf("%d applied", groupCountWithin(ordered, o.g, limit)), rightEdge)
				logStepInternals(o.g.st)
				headerShown = false
			}
			fileStart := time.Now()
			if err := apply.File(ctx, d, o.p, o.g.st, dbDir, cli.Version, executedBy, host, cfg.PGDatabase, false); err != nil {
				return fmt.Errorf("%s failed: %w", o.p.FilePath, err)
			}
			log.Step(o.p.FileName, time.Since(fileStart).Round(time.Millisecond).String(), rightEdge)
			log.Detail("      sha %s  size %dB  pos %d", shortSha(o.p.Sha), o.p.Size, o.p.Position)
			logObjects(objCols, objByFile[o.p.FilePath], fileContent[o.p.FilePath], o.p.FileName, &headerShown)
			applied++
		}
		log.Plain("")
		log.Success("applied %d files in %s", applied, time.Since(start).Round(time.Millisecond))
		if remain := len(ordered) - 1 - limit; remain > 0 {
			log.Info("stopped after %s, %d pending file(s) remain", target, remain)
		}
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

type orderedPending struct {
	p apply.Pending
	g *pendingGroup
}

func flatten(groups []*pendingGroup) []orderedPending {
	out := []orderedPending{}
	for _, g := range groups {
		for _, p := range g.files {
			out = append(out, orderedPending{p: p, g: g})
		}
	}
	return out
}

func groupCountWithin(ordered []orderedPending, g *pendingGroup, limit int) int {
	n := 0
	for i := 0; i <= limit && i < len(ordered); i++ {
		if ordered[i].g == g {
			n++
		}
	}
	return n
}

func fileToken(name string) string {
	v, s, _, ok := steps.ParseFilename(name)
	if !ok {
		return ""
	}
	return s + ":" + v
}

func resolveTarget(target string, ordered []orderedPending) (int, error) {
	t := strings.TrimSpace(target)
	if t == "" || strings.EqualFold(t, "all") {
		return len(ordered) - 1, nil
	}
	if n, err := strconv.Atoi(t); err == nil {
		if n < 1 || n > len(ordered) {
			return -1, fmt.Errorf("target %q out of range, pick 1 to %d", t, len(ordered))
		}
		return n - 1, nil
	}
	if slug, ver, ok := strings.Cut(t, ":"); ok {
		for i, o := range ordered {
			fv, fs, _, pok := steps.ParseFilename(o.p.FileName)
			if pok && strings.EqualFold(fs, slug) && fv == ver {
				return i, nil
			}
		}
		return -1, fmt.Errorf("no pending file matches slug:version %q", t)
	}
	last := -1
	for i, o := range ordered {
		if strings.EqualFold(o.g.st.Slug, t) {
			last = i
		}
	}
	if last >= 0 {
		return last, nil
	}
	return -1, fmt.Errorf("target %q matched no number, slug:version, or step slug", t)
}

func renderList(ordered []orderedPending) string {
	var b strings.Builder
	var cur *pendingGroup
	for i, o := range ordered {
		if o.g != cur {
			cur = o.g
			meta := "type=" + o.g.st.Type
			if o.g.st.Slug != "" {
				meta += " slug=" + o.g.st.Slug
			}
			b.WriteString(fmt.Sprintf("\n▸ %s  %s\n", o.g.name, meta))
		}
		b.WriteString(fmt.Sprintf("  %3d  %-44s  %s\n", i+1, o.p.FileName, fileToken(o.p.FileName)))
	}
	b.WriteString("\n")
	return b.String()
}

func selectTargets(target string, ordered []orderedPending) ([]int, error) {
	t := strings.TrimSpace(target)
	if t == "" {
		return nil, fmt.Errorf("run requires a target or --interactive")
	}
	if n, err := strconv.Atoi(t); err == nil {
		if n < 1 || n > len(ordered) {
			return nil, fmt.Errorf("target %q out of range, pick 1 to %d", t, len(ordered))
		}
		return []int{n - 1}, nil
	}
	if slug, ver, ok := strings.Cut(t, ":"); ok {
		for i, o := range ordered {
			fv, fs, _, pok := steps.ParseFilename(o.p.FileName)
			if pok && strings.EqualFold(fs, slug) && fv == ver {
				return []int{i}, nil
			}
		}
		return nil, fmt.Errorf("no file matches slug:version %q", t)
	}
	for i, o := range ordered {
		if strings.EqualFold(o.p.FileName, t) {
			return []int{i}, nil
		}
	}
	for i, o := range ordered {
		if o.p.FilePath == t {
			return []int{i}, nil
		}
	}
	idxs := []int{}
	for i, o := range ordered {
		if strings.EqualFold(o.g.st.Slug, t) {
			idxs = append(idxs, i)
		}
	}
	if len(idxs) > 0 {
		return idxs, nil
	}
	return nil, fmt.Errorf("target %q matched no number, slug:version, file name, path, or step slug", t)
}

func readToken(r *bufio.Reader, hint string, validate func(string) error) (string, error) {
	for {
		fmt.Print(hint)
		line, err := r.ReadString('\n')
		tok := strings.TrimSpace(line)
		if tok == "" {
			if err != nil {
				return "", fmt.Errorf("no selection provided")
			}
			continue
		}
		if verr := validate(tok); verr != nil {
			log.Warn("%v", verr)
			if err != nil {
				return "", verr
			}
			continue
		}
		return tok, nil
	}
}

func promptTarget(in io.Reader, ordered []orderedPending) (int, string, error) {
	fmt.Print(renderList(ordered))
	tok, err := readToken(bufio.NewReader(in), "stop after which migration?  number | slug | slug:version | all  › ",
		func(t string) error { _, e := resolveTarget(t, ordered); return e })
	if err != nil {
		return 0, "", err
	}
	limit, _ := resolveTarget(tok, ordered)
	return limit, tok, nil
}

func promptRun(in io.Reader, ordered []orderedPending) ([]int, string, error) {
	fmt.Print(renderList(ordered))
	tok, err := readToken(bufio.NewReader(in), "run which step or file?  number | slug | slug:version  › ",
		func(t string) error { _, e := selectTargets(t, ordered); return e })
	if err != nil {
		return nil, "", err
	}
	idxs, _ := selectTargets(tok, ordered)
	return idxs, tok, nil
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

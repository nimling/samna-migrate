package merge

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/dump"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/steps"
)

type Ident struct {
	Kind string
	Name string
}

type owner struct {
	Rel     string
	Abs     string
	Schemas []string
}

// Rebase folds every migration object into the base step folders. An object an
// existing base file owns gets its live definition spliced in place. A new
// concept is grouped with the rest of its source migration's new objects into a
// new file in the base step that owns its schema, named from the migration and
// versioned after that folder's existing files. Pure schema migrations empty
// out; migrations carrying data are the only residue.
func Rebase(ctx context.Context, d *db.DB, cfg *config.Config, stepsCfg *steps.Config, dbDir, toolVersion string, force bool) error {
	upgradedDir := filepath.Join(filepath.Dir(cfg.StepsFile), ".upgraded")
	if info, err := os.Stat(upgradedDir); err == nil && info.IsDir() {
		if hasContent(upgradedDir) {
			if !force {
				return fmt.Errorf(".upgraded/ already exists with content. Use --force to overwrite")
			}
			os.RemoveAll(upgradedDir)
		}
	}

	pending, err := pendingCount(ctx, d)
	if err != nil {
		return err
	}
	if pending > 0 {
		return fmt.Errorf("%d pending migrations on disk. Run 'smig up' first", pending)
	}

	if err := os.MkdirAll(upgradedDir, 0o755); err != nil {
		return err
	}

	registry, err := buildIdentifierRegistry(stepsCfg, dbDir)
	if err != nil {
		return err
	}
	schemaTarget := buildSchemaTargets(stepsCfg)

	log.Header("pass 1: route migration objects")

	migOut := filepath.Join(upgradedDir, "migrations")
	os.MkdirAll(migOut, 0o755)
	droppedDir := filepath.Join(upgradedDir, "dropped")

	plan := map[string][]Ident{}
	planSchemas := map[string][]string{}
	seen := map[string]map[string]bool{}
	addToPlan := func(o owner, id Ident) {
		target := o.Rel
		planSchemas[target] = o.Schemas
		if seen[target] == nil {
			seen[target] = map[string]bool{}
		}
		key := id.Kind + " " + id.Name
		if seen[target][key] {
			return
		}
		seen[target][key] = true
		plan[target] = append(plan[target], id)
	}

	newGroups := map[string][]Ident{}
	newAbs := map[string]string{}
	var newOrder []string

	for _, st := range stepsCfg.Steps {
		if st.Type != "migration" {
			continue
		}
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return err
		}
		for _, f := range files {
			segs, err := fileSegments(f.AbsPath)
			if err != nil {
				return err
			}
			var news []Ident
			var data []string
			existing := 0
			newSeen := map[string]bool{}
			for _, s := range segs {
				if s.ident == nil {
					data = append(data, strings.TrimSpace(s.text))
					continue
				}
				if o, ok := registry[s.ident.Name]; ok {
					addToPlan(o, *s.ident)
					existing++
					continue
				}
				key := s.ident.Kind + " " + s.ident.Name
				if !newSeen[key] {
					newSeen[key] = true
					news = append(news, *s.ident)
				}
			}
			if len(news) > 0 {
				newGroups[f.Name] = news
				newAbs[f.Name] = f.AbsPath
				newOrder = append(newOrder, f.Name)
			}
			if err := os.WriteFile(filepath.Join(migOut, f.Name), []byte{}, 0o644); err != nil {
				return err
			}
			if len(data) > 0 {
				body := strings.Join(data, "\n\n") + "\n"
				if err := os.MkdirAll(droppedDir, 0o755); err != nil {
					return err
				}
				if err := os.WriteFile(filepath.Join(droppedDir, f.Name), []byte(body), 0o644); err != nil {
					return err
				}
				log.Warn("  ~ %s folded; %d data statements set aside in .upgraded/dropped for review", f.Name, len(data))
			} else {
				log.Success("  ✓ %s folded (%d existing, %d new)", f.Name, existing, len(news))
			}
		}
	}

	log.Header("pass 2: splice live definitions into existing base files")

	targets := make([]string, 0, len(plan))
	for t := range plan {
		targets = append(targets, t)
	}
	sort.Strings(targets)

	abs := absByRel(stepsCfg, dbDir)
	for _, target := range targets {
		src, ok := abs[target]
		if !ok {
			return fmt.Errorf("splice target %s not resolvable on disk", target)
		}
		b, err := os.ReadFile(src)
		if err != nil {
			return err
		}
		content := string(b)
		spliced := 0
		for _, id := range plan[target] {
			def, err := dump.LiveDefinition(ctx, d, id.Kind, id.Name, planSchemas[target])
			if err != nil {
				return fmt.Errorf("live definition %s %s: %w", id.Kind, id.Name, err)
			}
			if def == "" {
				log.Warn("    %s %s absent from live database, removed from %s", strings.ToLower(id.Kind), id.Name, target)
				for _, dep := range dependentPatterns(id.Kind, id.Name) {
					content = spliceStatement(content, dep, "")
				}
			} else {
				spliced++
			}
			for _, aux := range auxPatterns(id.Kind, id.Name) {
				content = spliceStatement(content, aux, "")
			}
			content = spliceStatement(content, headPattern(id.Kind, id.Name), def)
		}
		out := filepath.Join(upgradedDir, target)
		os.MkdirAll(filepath.Dir(out), 0o755)
		if err := os.WriteFile(out, []byte(content), 0o644); err != nil {
			return err
		}
		log.Success("  %s: %d definitions spliced", target, spliced)
	}

	log.Header("pass 3: new concepts into new base files")

	nextVersion := map[string]int{}
	for _, name := range newOrder {
		news := newGroups[name]
		folder, folderSchemas := targetFolderFor(news, schemaTarget)
		if folder == "" {
			if err := copyFile(newAbs[name], filepath.Join(migOut, name)); err != nil {
				return err
			}
			log.Warn("  ! %s new objects have no schema target, kept", name)
			continue
		}
		if _, ok := nextVersion[folder]; !ok {
			nextVersion[folder] = maxMajor(stepsCfg, dbDir, folder) + 1
		}
		major := nextVersion[folder]
		nextVersion[folder] = major + 1
		_, _, label, _ := steps.ParseFilename(name)
		if label == "" {
			label = strings.TrimSuffix(name, ".sql")
		}
		outName := fmt.Sprintf("V%d.0__%s.sql", major, label)
		var body strings.Builder
		count := 0
		for _, id := range news {
			def, err := dump.LiveDefinition(ctx, d, id.Kind, id.Name, folderSchemas)
			if err != nil {
				return fmt.Errorf("live definition %s %s: %w", id.Kind, id.Name, err)
			}
			if def == "" {
				continue
			}
			body.WriteString(def)
			body.WriteString("\n\n")
			count++
		}
		if count == 0 {
			continue
		}
		out := filepath.Join(upgradedDir, folder, outName)
		os.MkdirAll(filepath.Dir(out), 0o755)
		if err := os.WriteFile(out, []byte(body.String()), 0o644); err != nil {
			return err
		}
		log.Success("  %s -> %s (%d objects)", name, filepath.Join(folder, outName), count)
	}

	log.Header("pass 4: deferred column defaults")

	tableSeen := map[string]bool{}
	var tables []Ident
	for _, ids := range plan {
		for _, id := range ids {
			if id.Kind == "TABLE" && !tableSeen[id.Name] {
				tableSeen[id.Name] = true
				tables = append(tables, id)
			}
		}
	}
	for _, ids := range newGroups {
		for _, id := range ids {
			if id.Kind == "TABLE" && !tableSeen[id.Name] {
				tableSeen[id.Name] = true
				tables = append(tables, id)
			}
		}
	}
	sort.Slice(tables, func(i, j int) bool { return tables[i].Name < tables[j].Name })

	deferred := map[string][]string{}
	for _, id := range tables {
		alters, err := dump.DeferredDefaults(ctx, d, id.Name)
		if err != nil {
			return fmt.Errorf("deferred defaults %s: %w", id.Name, err)
		}
		if len(alters) == 0 {
			continue
		}
		sc := "public"
		if i := strings.LastIndex(id.Name, "."); i >= 0 {
			sc = id.Name[:i]
		}
		o, ok := schemaTarget[sc]
		if !ok {
			continue
		}
		deferred[o.Rel] = append(deferred[o.Rel], alters...)
	}
	folders := make([]string, 0, len(deferred))
	for f := range deferred {
		folders = append(folders, f)
	}
	sort.Strings(folders)
	for _, folder := range folders {
		if _, ok := nextVersion[folder]; !ok {
			nextVersion[folder] = maxMajor(stepsCfg, dbDir, folder) + 1
		}
		major := nextVersion[folder]
		nextVersion[folder] = major + 1
		outName := fmt.Sprintf("V%d.0__deferred_defaults.sql", major)
		out := filepath.Join(upgradedDir, folder, outName)
		os.MkdirAll(filepath.Dir(out), 0o755)
		body := strings.Join(deferred[folder], "\n") + "\n"
		if err := os.WriteFile(out, []byte(body), 0o644); err != nil {
			return err
		}
		log.Success("  %s (%d defaults)", filepath.Join(folder, outName), len(deferred[folder]))
	}

	log.Success(".upgraded/ ready at %s", upgradedDir)
	log.Info("review the tree, run smig verify, then smig merge --apply")
	return nil
}

// buildSchemaTargets maps each schema to the base step that owns it, the first
// base step in declared order whose schemas list contains it. That step's
// folder is the home for new objects of that schema.
func buildSchemaTargets(stepsCfg *steps.Config) map[string]owner {
	out := map[string]owner{}
	for _, st := range stepsCfg.Steps {
		if st.Type != "base" {
			continue
		}
		for _, sc := range st.Schemas {
			if _, ok := out[sc]; ok {
				continue
			}
			folder := st.Slug
			if len(st.Include) > 0 {
				folder = strings.Trim(st.Include[0].Path, "/")
			}
			out[sc] = owner{Rel: folder, Schemas: st.Schemas}
		}
	}
	return out
}

func targetFolderFor(news []Ident, schemaTarget map[string]owner) (string, []string) {
	for _, id := range news {
		sc := "public"
		if i := strings.LastIndex(id.Name, "."); i >= 0 {
			sc = id.Name[:i]
		}
		if o, ok := schemaTarget[sc]; ok {
			return o.Rel, o.Schemas
		}
	}
	return "", nil
}

func maxMajor(stepsCfg *steps.Config, dbDir, folder string) int {
	max := 0
	for _, st := range stepsCfg.Steps {
		files, _ := st.ResolveFiles(dbDir)
		for _, f := range files {
			if f.Folder != folder {
				continue
			}
			ver, _, _, ok := steps.ParseFilename(f.Name)
			if !ok {
				continue
			}
			dot := strings.IndexByte(ver, '.')
			major := ver
			if dot >= 0 {
				major = ver[:dot]
			}
			n := 0
			for _, c := range major {
				if c < '0' || c > '9' {
					n = 0
					break
				}
				n = n*10 + int(c-'0')
			}
			if n > max {
				max = n
			}
		}
	}
	return max
}

func hasContent(p string) bool {
	entries, err := os.ReadDir(p)
	return err == nil && len(entries) > 0
}

func pendingCount(ctx context.Context, d *db.DB) (int, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `SELECT COUNT(*) FROM samna_migrate.file WHERE state = 'pending'`).Scan(&n)
	return n, err
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func buildIdentifierRegistry(stepsCfg *steps.Config, dbDir string) (map[string]owner, error) {
	reg := map[string]owner{}
	for _, st := range stepsCfg.Steps {
		if st.Type == "migration" {
			continue
		}
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			ids, _, err := fileStatements(f.AbsPath)
			if err != nil {
				return nil, err
			}
			o := owner{Rel: filepath.Join(f.Folder, f.Name), Abs: f.AbsPath, Schemas: st.Schemas}
			for _, id := range ids {
				if _, ok := reg[id.Name]; !ok {
					reg[id.Name] = o
				}
				if i := strings.LastIndex(id.Name, "."); i >= 0 {
					bare := id.Name[i+1:]
					if _, ok := reg[bare]; !ok {
						reg[bare] = o
					}
				}
			}
		}
	}
	return reg, nil
}

func absByRel(stepsCfg *steps.Config, dbDir string) map[string]string {
	out := map[string]string{}
	for _, st := range stepsCfg.Steps {
		files, _ := st.ResolveFiles(dbDir)
		for _, f := range files {
			out[filepath.Join(f.Folder, f.Name)] = f.AbsPath
		}
	}
	return out
}

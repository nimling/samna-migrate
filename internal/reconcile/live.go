package reconcile

import (
	"context"
	"os"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/sqlscan"
	"github.com/nimling/samna-migrate/internal/steps"
)

type LiveDiff struct {
	Kind string
	Name string
	File string
	Line int
}

type LiveReport struct {
	Schemas []string
	Missing []LiveDiff
	Extra   []LiveDiff
	Matched int
}

func (r *LiveReport) Drifted() bool {
	return len(r.Missing) > 0 || len(r.Extra) > 0
}

var liveKinds = map[string]bool{"function": true, "table": true, "view": true, "type": true, "sequence": true}

func LiveCompare(ctx context.Context, live *db.DB, stepsCfg *steps.Config, dbDir string) (*LiveReport, error) {
	schemas := schemaUnion(stepsCfg)
	local, err := collectLocalObjects(stepsCfg, dbDir)
	if err != nil {
		return nil, err
	}
	inv, err := Inventory(ctx, live, schemas)
	if err != nil {
		return nil, err
	}
	liveSet := liveObjectKeys(inv)

	rep := &LiveReport{Schemas: schemas}
	for key, ld := range local {
		if _, ok := liveSet[key]; ok {
			rep.Matched++
		} else {
			rep.Missing = append(rep.Missing, ld)
		}
	}
	for key, kd := range liveSet {
		if _, ok := local[key]; !ok {
			rep.Extra = append(rep.Extra, kd)
		}
	}
	sort.Slice(rep.Missing, func(i, j int) bool { return liveLess(rep.Missing[i], rep.Missing[j]) })
	sort.Slice(rep.Extra, func(i, j int) bool { return liveLess(rep.Extra[i], rep.Extra[j]) })
	return rep, nil
}

func liveLess(a, b LiveDiff) bool {
	if a.Kind != b.Kind {
		return a.Kind < b.Kind
	}
	return a.Name < b.Name
}

func collectLocalObjects(stepsCfg *steps.Config, dbDir string) (map[string]LiveDiff, error) {
	out := map[string]LiveDiff{}
	for _, st := range stepsCfg.Steps {
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			b, err := os.ReadFile(f.AbsPath)
			if err != nil {
				return nil, err
			}
			for _, o := range sqlscan.Scan(string(b)) {
				if !liveKinds[o.Kind] {
					continue
				}
				name := normName(o.Name)
				key := o.Kind + ":" + name
				if _, ok := out[key]; !ok {
					out[key] = LiveDiff{Kind: o.Kind, Name: name, File: f.Rel, Line: o.Line}
				}
			}
		}
	}
	return out, nil
}

func liveObjectKeys(inv map[string]string) map[string]LiveDiff {
	out := map[string]LiveDiff{}
	for identity := range inv {
		sp := strings.IndexByte(identity, ' ')
		if sp < 0 {
			continue
		}
		kind := mapLiveKind(identity[:sp])
		if kind == "" {
			continue
		}
		rest := strings.TrimSpace(identity[sp+1:])
		if kind == "function" {
			if p := strings.IndexByte(rest, '('); p >= 0 {
				rest = rest[:p]
			}
		}
		name := normName(rest)
		key := kind + ":" + name
		if _, ok := out[key]; !ok {
			out[key] = LiveDiff{Kind: kind, Name: name}
		}
	}
	return out
}

func mapLiveKind(k string) string {
	switch k {
	case "function", "table", "view", "sequence":
		return k
	case "type", "enum":
		return "type"
	}
	return ""
}

func normName(s string) string {
	s = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(s, `"`, "")))
	if !strings.Contains(s, ".") {
		s = "public." + s
	}
	return s
}

func RenderLive(rep *LiveReport, dbLabel string) {
	log.Header("live comparison: " + dbLabel)
	log.Info("matched %d  missing %d  extra %d  in %s",
		rep.Matched, len(rep.Missing), len(rep.Extra), strings.Join(rep.Schemas, ","))
	if !rep.Drifted() {
		log.Success("live database matches the local objects by name")
		return
	}
	kindW := 0
	for _, d := range rep.Missing {
		if len(d.Kind) > kindW {
			kindW = len(d.Kind)
		}
	}
	for _, d := range rep.Extra {
		if len(d.Kind) > kindW {
			kindW = len(d.Kind)
		}
	}
	for _, d := range rep.Missing {
		log.Warn("  missing in live  %-*s %s  %s:%d", kindW, d.Kind, d.Name, d.File, d.Line)
	}
	for _, d := range rep.Extra {
		log.Info("  extra in live    %-*s %s", kindW, d.Kind, d.Name)
	}
}

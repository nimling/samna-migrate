package reconcile

import (
	"os"
	"strings"

	"github.com/nimling/samna-migrate/internal/sqlscan"
	"github.com/nimling/samna-migrate/internal/steps"
)

type LiveDiff struct {
	Kind string
	Name string
	File string
	Line int
}

func objIndexKey(kind, name, table string) string {
	return kind + ":" + name + ":" + table
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
				if o.Name == "" || !createKinds[o.Kind] {
					continue
				}
				key := objIndexKey(o.Kind, normName(o.Name), objTable(o))
				if _, ok := out[key]; !ok {
					out[key] = LiveDiff{Kind: o.Kind, Name: normName(o.Name), File: f.Rel, Line: o.Line}
				}
			}
		}
	}
	return out, nil
}

func parseIdentity(identity string) (kind, name, table, display string, ok bool) {
	sp := strings.IndexByte(identity, ' ')
	if sp < 0 {
		return "", "", "", "", false
	}
	head := identity[:sp]
	rest := strings.TrimSpace(identity[sp+1:])
	display = identity
	switch head {
	case "function", "view", "sequence", "table", "index":
		return head, normName(stripArgs(rest)), "", display, true
	case "type", "enum":
		return "type", normName(rest), "", display, true
	case "constraint", "trigger":
		tbl, n := splitOwned(rest)
		return head, n, normName(tbl), display, true
	case "grant", "comment":
		return head, strings.ToLower(rest), "", display, true
	}
	return "", "", "", "", false
}

func stripArgs(s string) string {
	if p := strings.IndexByte(s, '('); p >= 0 {
		return s[:p]
	}
	return s
}

func splitOwned(rest string) (table, name string) {
	dot := strings.LastIndexByte(rest, '.')
	if dot < 0 {
		return "", strings.ToLower(rest)
	}
	return normName(rest[:dot]), strings.ToLower(rest[dot+1:])
}

func normName(s string) string {
	s = strings.ToLower(strings.TrimSpace(strings.ReplaceAll(s, `"`, "")))
	if !strings.Contains(s, ".") {
		s = "public." + s
	}
	return s
}

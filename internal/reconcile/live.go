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

var liveKinds = map[string]bool{"function": true, "table": true, "view": true, "type": true, "sequence": true}

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

func identityKind(identity string) (kind, name string, ok bool) {
	sp := strings.IndexByte(identity, ' ')
	if sp < 0 {
		return "", "", false
	}
	kind = mapLiveKind(identity[:sp])
	if kind == "" {
		return "", "", false
	}
	rest := strings.TrimSpace(identity[sp+1:])
	if kind == "function" {
		if p := strings.IndexByte(rest, '('); p >= 0 {
			rest = rest[:p]
		}
	}
	return kind, normName(rest), true
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

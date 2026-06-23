package reconcile

import (
	"context"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/sqlscan"
	"github.com/nimling/samna-migrate/internal/steps"
)

const renameThreshold = 0.8

type ObjRef struct {
	Kind string
	Name string
	File string
	Line int
	Sig  string
	Body string
}

type ObjChange struct {
	Kind    string
	Name    string
	OldName string
	From    *ObjRef
	To      *ObjRef
	Reasons []string
	Hunks   []Hunk
}

type ObjReport struct {
	Changes []ObjChange
	Same    int
}

func (r *ObjReport) Drifted() bool { return len(r.Changes) > 0 }

func AnalyzeObjects(ctx context.Context, d *db.DB, stepsCfg *steps.Config, dbDir string) (*ObjReport, error) {
	deployed, err := loadDeployed(ctx, d)
	if err != nil {
		return nil, err
	}
	local, err := loadLocal(stepsCfg, dbDir)
	if err != nil {
		return nil, err
	}
	depBodies := map[string]string{}
	for p, df := range deployed {
		if df.HasSQL {
			depBodies[p] = df.AppliedSQL
		}
	}
	locBodies := map[string]string{}
	for p, lf := range local {
		locBodies[p] = lf.Content
	}
	return analyzeObjects(depBodies, locBodies), nil
}

func analyzeObjects(deployed, local map[string]string) *ObjReport {
	depIdx := buildObjIndex(deployed)
	locIdx := buildObjIndex(local)
	rep := &ObjReport{}

	var deleted, added []ObjRef
	for _, key := range mergedObjKeys(depIdx, locIdx) {
		dep := depIdx[key]
		loc := locIdx[key]
		n := len(dep)
		if len(loc) > n {
			n = len(loc)
		}
		for i := 0; i < n; i++ {
			switch {
			case i < len(dep) && i < len(loc):
				if ch, ok := pairChange(dep[i], loc[i]); ok {
					rep.Changes = append(rep.Changes, ch)
				} else {
					rep.Same++
				}
			case i < len(dep):
				deleted = append(deleted, dep[i])
			default:
				added = append(added, loc[i])
			}
		}
	}

	usedAdd := make([]bool, len(added))
	for _, d := range deleted {
		matched := false
		for ai, a := range added {
			if usedAdd[ai] || a.Kind != d.Kind {
				continue
			}
			if similar(d.Body, a.Body) >= renameThreshold {
				usedAdd[ai] = true
				matched = true
				ch := ObjChange{Kind: d.Kind, Name: a.Name, OldName: d.Name, From: refOf(d), To: refOf(a), Reasons: []string{"renamed"}}
				if d.Body != a.Body {
					ch.Reasons = append(ch.Reasons, "content")
					ch.Hunks = Hunkify(Diff(splitLines(d.Body), splitLines(a.Body)), contextLines)
				}
				rep.Changes = append(rep.Changes, ch)
				break
			}
		}
		if !matched {
			rep.Changes = append(rep.Changes, ObjChange{Kind: d.Kind, Name: d.Name, From: refOf(d), Reasons: []string{"deleted"}})
		}
	}
	for ai, a := range added {
		if usedAdd[ai] {
			continue
		}
		rep.Changes = append(rep.Changes, ObjChange{Kind: a.Kind, Name: a.Name, To: refOf(a), Reasons: []string{"added"}})
	}

	sort.Slice(rep.Changes, func(i, j int) bool {
		if rep.Changes[i].Kind != rep.Changes[j].Kind {
			return rep.Changes[i].Kind < rep.Changes[j].Kind
		}
		return rep.Changes[i].Name < rep.Changes[j].Name
	})
	return rep
}

func pairChange(d, l ObjRef) (ObjChange, bool) {
	var reasons []string
	if d.Sig != l.Sig {
		reasons = append(reasons, "signature")
	}
	if d.Body != l.Body {
		reasons = append(reasons, "content")
	}
	if d.File != l.File {
		reasons = append(reasons, "moved")
	} else if d.Line != l.Line {
		reasons = append(reasons, "position")
	}
	if len(reasons) == 0 {
		return ObjChange{}, false
	}
	ch := ObjChange{Kind: d.Kind, Name: l.Name, From: refOf(d), To: refOf(l), Reasons: reasons}
	if d.Body != l.Body {
		ch.Hunks = Hunkify(Diff(splitLines(d.Body), splitLines(l.Body)), contextLines)
	}
	return ch, true
}

func refOf(r ObjRef) *ObjRef {
	c := r
	return &c
}

func buildObjIndex(files map[string]string) map[string][]ObjRef {
	idx := map[string][]ObjRef{}
	for path, content := range files {
		for _, o := range sqlscan.Scan(content) {
			if o.Name == "" {
				continue
			}
			name := normName(o.Name)
			key := o.Kind + "\x00" + name
			idx[key] = append(idx[key], ObjRef{
				Kind: o.Kind,
				Name: name,
				File: path,
				Line: o.Line,
				Sig:  sigOf(o),
				Body: normalize(o.SQL),
			})
		}
	}
	return idx
}

func mergedObjKeys(a, b map[string][]ObjRef) []string {
	seen := map[string]bool{}
	var out []string
	for k := range a {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	for k := range b {
		if !seen[k] {
			seen[k] = true
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func sigOf(o sqlscan.Object) string {
	var parts []string
	for _, s := range o.Stats {
		switch s.Key {
		case "at", "lines", "bytes", "body":
			continue
		}
		parts = append(parts, s.Key+"="+s.Val)
	}
	sort.Strings(parts)
	return strings.Join(parts, " ")
}

func similar(a, b string) float64 {
	la := splitLines(a)
	lb := splitLines(b)
	if len(la) == 0 && len(lb) == 0 {
		return 1
	}
	set := map[string]int{}
	for _, l := range la {
		set[strings.TrimSpace(l)]++
	}
	common := 0
	for _, l := range lb {
		t := strings.TrimSpace(l)
		if set[t] > 0 {
			set[t]--
			common++
		}
	}
	m := len(la)
	if len(lb) > m {
		m = len(lb)
	}
	if m == 0 {
		return 1
	}
	return float64(common) / float64(m)
}


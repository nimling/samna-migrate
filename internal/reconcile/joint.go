package reconcile

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/git"
	"github.com/nimling/samna-migrate/internal/log"
)

type Sections struct {
	Files   bool
	Objects bool
	Git     bool
	Db      bool
}

type ColumnChange struct {
	Name   string `json:"name"`
	Change string `json:"change"`
	Live   string `json:"live,omitempty"`
	Built  string `json:"built,omitempty"`
}

type JointObj struct {
	Kind           string         `json:"kind"`
	Name           string         `json:"name"`
	Table          string         `json:"table,omitempty"`
	Phase          int            `json:"phase"`
	RenamedTo      string         `json:"renamed_to,omitempty"`
	Signature      string         `json:"signature,omitempty"`
	Reasons        []string       `json:"reasons"`
	Remediation    string         `json:"remediation,omitempty"`
	Destructive    bool           `json:"destructive,omitempty"`
	OwnerExtension string         `json:"owner_extension,omitempty"`
	File           string         `json:"file,omitempty"`
	Line           int            `json:"line,omitempty"`
	MovedFrom      string         `json:"moved_from,omitempty"`
	Commit         string         `json:"deployed_commit,omitempty"`
	Columns        []ColumnChange `json:"columns,omitempty"`
	DesiredSQL     string         `json:"desired_sql,omitempty"`
	CurrentDDL     string         `json:"current_live_ddl,omitempty"`

	fromDB      bool
	sourceHunks []Hunk
}

type JointFile struct {
	Path    string `json:"path"`
	Class   string `json:"class"`
	Commit  string `json:"deployed_commit,omitempty"`
	GitDiff string `json:"git_diff,omitempty"`

	hunks []Hunk
}

type Joint struct {
	Database          string       `json:"database"`
	ContainerRan      bool         `json:"container_ran"`
	ContainerComplete bool         `json:"container_complete"`
	GitRepo           bool         `json:"git_repo"`
	ObjectsSame       int          `json:"objects_unchanged"`
	ExtensionsIgnored int          `json:"extension_objects_ignored"`
	Objects           []JointObj   `json:"objects"`
	Files             []JointFile  `json:"files"`
	BuildErrors       []BuildError `json:"build_errors,omitempty"`

	sel Sections
}

func phaseOf(kind string) int {
	switch kind {
	case "extension":
		return 0
	case "schema":
		return 1
	case "type":
		return 2
	case "table":
		return 3
	case "sequence":
		return 4
	case "function":
		return 5
	case "view":
		return 6
	case "index":
		return 7
	case "constraint":
		return 8
	case "trigger":
		return 9
	case "policy":
		return 10
	case "grant":
		return 11
	case "comment":
		return 12
	}
	return 5
}

func BuildJoint(sel Sections, dbLabel string, audit *Report, obj *ObjReport, cdiff *ContainerDiff, commits map[string]string, dbDir string) *Joint {
	complete := cdiff != nil && len(cdiff.BuildErrors) == 0
	j := &Joint{
		Database:          dbLabel,
		ContainerRan:      cdiff != nil,
		ContainerComplete: complete,
		GitRepo:           git.IsRepo(dbDir),
		ObjectsSame:       obj.Same,
		sel:               sel,
	}

	byKey := map[string]*JointObj{}
	var order []string
	get := func(kind, name, table string) *JointObj {
		key := objIndexKey(kind, name, table)
		if jo, ok := byKey[key]; ok {
			return jo
		}
		jo := &JointObj{Kind: kind, Name: name, Table: table, Phase: phaseOf(kind)}
		byKey[key] = jo
		order = append(order, key)
		return jo
	}

	if sel.Objects {
		for i := range obj.Changes {
			ch := &obj.Changes[i]
			jo := get(ch.Kind, ch.Name, ch.Table)
			jo.Reasons = append(jo.Reasons, ch.Reasons...)
			jo.sourceHunks = ch.Hunks
			if ch.OldName != "" {
				jo.RenamedTo = ch.Name
			}
			if ch.To != nil {
				jo.File, jo.Line = ch.To.File, ch.To.Line
				jo.DesiredSQL = ch.To.Body
				jo.Commit = commits[ch.To.File]
			}
			if ch.From != nil && (ch.To == nil || ch.From.File != ch.To.File) {
				jo.MovedFrom = fmt.Sprintf("%s:%d", ch.From.File, ch.From.Line)
			}
		}
	}

	if sel.Db && cdiff != nil {
		liveObj := func(id, reason string) *JointObj {
			kind, name, table, display, ok := parseIdentity(id)
			if !ok {
				return nil
			}
			jo := get(kind, name, table)
			jo.fromDB = true
			jo.Reasons = append(jo.Reasons, reason)
			jo.Signature = display
			if v, ok := cdiff.live[id]; ok {
				jo.CurrentDDL = v
			}
			if jo.File == "" {
				if ld, ok := cdiff.index[objIndexKey(kind, name, table)]; ok {
					jo.File, jo.Line = ld.File, ld.Line
					jo.Commit = commits[ld.File]
				}
			}
			return jo
		}
		for _, id := range cdiff.Diff.Different {
			jo := liveObj(id, "live differs")
			if jo == nil {
				continue
			}
			if jo.Kind == "table" {
				jo.Columns = columnChanges(cdiff.live[id], cdiff.cand[id])
			}
			if jo.DesiredSQL == "" {
				jo.DesiredSQL = cdiff.cand[id]
			}
		}
		for _, id := range cdiff.Diff.Missing {
			if cdiff.extObjs[id] != "" {
				j.ExtensionsIgnored++
				continue
			}
			liveObj(id, "only in live")
		}
		for _, id := range cdiff.Diff.Extra {
			if jo := liveObj(id, "produced, not in live"); jo != nil && jo.DesiredSQL == "" {
				jo.DesiredSQL = cdiff.cand[id]
			}
		}
		j.BuildErrors = cdiff.BuildErrors
	}

	for _, key := range order {
		jo := byKey[key]
		jo.Reasons = dedupe(jo.Reasons)
		jo.Remediation = remediation(jo, j.ContainerRan, complete)
		jo.Destructive = jo.Remediation == "drop" || hasDropColumn(jo.Columns)
		j.Objects = append(j.Objects, *jo)
	}
	sort.Slice(j.Objects, func(a, b int) bool {
		if j.Objects[a].Phase != j.Objects[b].Phase {
			return j.Objects[a].Phase < j.Objects[b].Phase
		}
		return j.Objects[a].Name < j.Objects[b].Name
	})

	if sel.Files || sel.Git {
		for _, f := range audit.Files {
			jf := JointFile{Path: f.FilePath, Class: f.Class.String(), Commit: commits[f.FilePath], hunks: f.Hunks}
			if sel.Git && j.GitRepo && jf.Commit != "" && f.Class != Added {
				jf.GitDiff = git.DiffSince(dbDir, jf.Commit, f.FilePath)
			}
			j.Files = append(j.Files, jf)
		}
	}
	return j
}

func remediation(jo *JointObj, containerRan, containerComplete bool) string {
	has := func(r string) bool {
		for _, x := range jo.Reasons {
			if x == r {
				return true
			}
		}
		return false
	}
	switch {
	case has("only in live"):
		if !containerComplete {
			return "review"
		}
		return "drop"
	case has("produced, not in live"):
		return "create"
	case has("live differs"):
		return "update"
	}
	if containerRan {
		return "none"
	}
	switch {
	case has("added"):
		return "create"
	case has("deleted"):
		return "drop"
	case has("signature"), has("content"):
		return "update"
	}
	return "none"
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func tableColumns(s string) map[string]string {
	m := map[string]string{}
	for _, ln := range strings.Split(s, "\n") {
		ln = strings.TrimRight(ln, " \t")
		if ln == "" {
			continue
		}
		if i := strings.IndexByte(ln, ' '); i >= 0 {
			m[ln[:i]] = ln[i+1:]
		} else {
			m[ln] = ""
		}
	}
	return m
}

func columnChanges(live, built string) []ColumnChange {
	lm, bm := tableColumns(live), tableColumns(built)
	var out []ColumnChange
	for name, bdef := range bm {
		if ldef, ok := lm[name]; !ok {
			out = append(out, ColumnChange{Name: name, Change: "add", Built: bdef})
		} else if ldef != bdef {
			out = append(out, ColumnChange{Name: name, Change: "alter", Live: ldef, Built: bdef})
		}
	}
	for name, ldef := range lm {
		if _, ok := bm[name]; !ok {
			out = append(out, ColumnChange{Name: name, Change: "drop", Live: ldef})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func hasDropColumn(cols []ColumnChange) bool {
	for _, c := range cols {
		if c.Change == "drop" {
			return true
		}
	}
	return false
}

func WriteJSON(w io.Writer, j *Joint) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(j)
}

func RenderJoint(j *Joint) {
	log.Header("reconcile: " + j.Database)
	remed := 0
	for _, o := range j.Objects {
		if o.Remediation != "" && o.Remediation != "none" {
			remed++
		}
	}
	log.Info("objects %d changed, %d unchanged   files %d   build errors %d   remediations %d",
		len(j.Objects), j.ObjectsSame, len(j.Files), len(j.BuildErrors), remed)
	if j.ContainerRan && !j.ContainerComplete {
		log.Warn("container build incomplete, %d files failed: only-in-live verdicts are downgraded to review", len(j.BuildErrors))
	}
	if j.ExtensionsIgnored > 0 {
		log.Detail("ignored %d extension owned objects on live", j.ExtensionsIgnored)
	}
	if len(j.Objects) == 0 && len(j.Files) == 0 && len(j.BuildErrors) == 0 {
		log.Success("no drift across the selected views")
		return
	}

	for _, o := range j.Objects {
		name := o.Name
		if o.RenamedTo != "" {
			name = o.Name + " (renamed)"
		}
		if o.Table != "" {
			name = o.Name + " on " + o.Table
		}
		loc := o.File
		if o.Line > 0 {
			loc = fmt.Sprintf("%s:%d", o.File, o.Line)
		}
		if o.MovedFrom != "" {
			loc = o.MovedFrom + " -> " + loc
		}
		tail := strings.Join(o.Reasons, ", ")
		if o.Remediation != "" && o.Remediation != "none" {
			tail += "  [" + o.Remediation + " on live]"
		}
		if o.Destructive {
			tail += "  destructive"
		}
		if o.Commit != "" {
			tail += "  (deployed " + shortCommit(o.Commit) + ")"
		}
		jointColor(o, fmt.Sprintf("  %s %s  %s  %s", o.Kind, name, loc, tail))
		if o.fromDB {
			log.Detail("    --- live")
			log.Detail("    +++ files")
			renderHunks(Hunkify(Diff(splitLines(o.CurrentDDL), splitLines(o.DesiredSQL)), contextLines))
		} else if len(o.sourceHunks) > 0 {
			renderHunks(o.sourceHunks)
		}
	}

	for _, f := range j.Files {
		if j.sel.Files {
			log.Warn("  file %s  %s", f.Class, f.Path)
			if len(f.hunks) > 0 {
				renderHunks(f.hunks)
			}
		}
		if j.sel.Git && f.GitDiff != "" {
			log.Detail("  git %s since %s", f.Path, shortCommit(f.Commit))
			renderGitDiffLines(f.GitDiff)
		}
	}

	for _, be := range j.BuildErrors {
		log.Warn("  build error  %s", be.File)
		log.Detail("      %s", be.Err)
	}
}

func jointColor(o JointObj, line string) {
	for _, r := range o.Reasons {
		if r == "added" || r == "produced, not in live" {
			log.Success("%s", line)
			return
		}
	}
	log.Warn("%s", line)
}

func renderGitDiffLines(diff string) {
	for _, ln := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(ln, "+++"), strings.HasPrefix(ln, "---"),
			strings.HasPrefix(ln, "diff "), strings.HasPrefix(ln, "index "):
			log.Detail("%s", ln)
		case strings.HasPrefix(ln, "@@"):
			log.DiffHunk(ln)
		case strings.HasPrefix(ln, "+"):
			log.DiffLine('+', ln[1:])
		case strings.HasPrefix(ln, "-"):
			log.DiffLine('-', ln[1:])
		default:
			log.DiffLine(' ', strings.TrimPrefix(ln, " "))
		}
	}
}

func shortCommit(c string) string {
	if len(c) > 12 {
		return c[:12]
	}
	return c
}

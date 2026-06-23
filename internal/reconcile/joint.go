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

type JointObj struct {
	Kind       string   `json:"kind"`
	Name       string   `json:"name"`
	RenamedTo  string   `json:"renamed_to,omitempty"`
	Signature  string   `json:"signature,omitempty"`
	Reasons    []string `json:"reasons"`
	Remediation string  `json:"remediation,omitempty"`
	File       string   `json:"file,omitempty"`
	Line       int      `json:"line,omitempty"`
	MovedFrom  string   `json:"moved_from,omitempty"`
	Commit     string   `json:"deployed_commit,omitempty"`
	DesiredSQL string   `json:"desired_sql,omitempty"`
	CurrentDDL string   `json:"current_live_ddl,omitempty"`

	sourceHunks []Hunk
	liveHunks   []Hunk
}

type JointFile struct {
	Path    string `json:"path"`
	Class   string `json:"class"`
	Commit  string `json:"deployed_commit,omitempty"`
	GitDiff string `json:"git_diff,omitempty"`
}

type Joint struct {
	Database     string       `json:"database"`
	ContainerRan bool         `json:"container_ran"`
	GitRepo      bool         `json:"git_repo"`
	ObjectsSame  int          `json:"objects_unchanged"`
	Objects      []JointObj   `json:"objects"`
	Files        []JointFile  `json:"files"`
	BuildErrors  []BuildError `json:"build_errors,omitempty"`
}

func BuildJoint(dbLabel string, audit *Report, obj *ObjReport, cdiff *ContainerDiff, commits map[string]string, dbDir string) *Joint {
	j := &Joint{Database: dbLabel, ContainerRan: cdiff != nil, GitRepo: git.IsRepo(dbDir), ObjectsSame: obj.Same}

	byKey := map[string]*JointObj{}
	var order []string
	get := func(kind, name string) *JointObj {
		key := kind + ":" + name
		if jo, ok := byKey[key]; ok {
			return jo
		}
		jo := &JointObj{Kind: kind, Name: name}
		byKey[key] = jo
		order = append(order, key)
		return jo
	}

	for i := range obj.Changes {
		ch := &obj.Changes[i]
		jo := get(ch.Kind, ch.Name)
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

	if cdiff != nil {
		liveObj := func(id, reason string) *JointObj {
			kind, name, ok := identityKind(id)
			if !ok {
				return nil
			}
			jo := get(kind, name)
			jo.Reasons = append(jo.Reasons, reason)
			jo.Signature = id
			if v, ok := cdiff.live[id]; ok {
				jo.CurrentDDL = v
			}
			if jo.File == "" {
				if ld, ok := cdiff.index[kind+":"+name]; ok {
					jo.File, jo.Line = ld.File, ld.Line
					jo.Commit = commits[ld.File]
				}
			}
			return jo
		}
		for _, id := range cdiff.Diff.Different {
			if jo := liveObj(id, "live differs"); jo != nil {
				jo.liveHunks = Hunkify(Diff(splitLines(cdiff.live[id]), splitLines(cdiff.cand[id])), contextLines)
				if jo.DesiredSQL == "" {
					jo.DesiredSQL = cdiff.cand[id]
				}
			}
		}
		for _, id := range cdiff.Diff.Missing {
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
		jo.Remediation = remediation(jo, j.ContainerRan)
		j.Objects = append(j.Objects, *jo)
	}
	sort.Slice(j.Objects, func(a, b int) bool {
		if j.Objects[a].Kind != j.Objects[b].Kind {
			return j.Objects[a].Kind < j.Objects[b].Kind
		}
		return j.Objects[a].Name < j.Objects[b].Name
	})

	for _, f := range audit.Files {
		switch f.Class {
		case Added, Dropped, Reordered:
			j.Files = append(j.Files, JointFile{Path: f.FilePath, Class: f.Class.String(), Commit: commits[f.FilePath]})
		case Changed:
			jf := JointFile{Path: f.FilePath, Class: "changed", Commit: commits[f.FilePath]}
			if j.GitRepo && jf.Commit != "" {
				jf.GitDiff = git.DiffSince(dbDir, jf.Commit, f.FilePath)
			}
			j.Files = append(j.Files, jf)
		}
	}
	return j
}

func remediation(jo *JointObj, containerRan bool) string {
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
	if len(j.Objects) == 0 && len(j.Files) == 0 && len(j.BuildErrors) == 0 {
		log.Success("no drift: the local tree, the deployed bodies, and the live server all agree")
		return
	}

	for _, o := range j.Objects {
		name := o.Name
		if o.RenamedTo != "" {
			name = o.Name + " (renamed)"
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
		if o.Commit != "" {
			tail += "  (deployed " + shortCommit(o.Commit) + ")"
		}
		jointColor(o, fmt.Sprintf("  %s %s  %s  %s", o.Kind, name, loc, tail))
		if len(o.sourceHunks) > 0 {
			log.Detail("    file change")
			renderHunks(o.sourceHunks)
		}
		if len(o.liveHunks) > 0 {
			log.Detail("    live vs built")
			renderHunks(o.liveHunks)
		}
	}

	for _, f := range j.Files {
		log.Warn("  file %s  %s", f.Class, f.Path)
		if f.GitDiff != "" {
			log.Detail("    git diff since %s", shortCommit(f.Commit))
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

package reconcile

import (
	"fmt"
	"sort"

	"github.com/nimling/samna-migrate/internal/log"
)

func Render(r *Report) {
	log.Header("reconcile: local tree against deployed state")
	if !r.Drifted() {
		log.Success("no drift: %d files match deployed state", r.Same)
		return
	}
	log.Info("added %d  dropped %d  changed %d  reordered %d  same %d",
		r.Added, r.Dropped, r.Changed, r.Reordered, r.Same)

	files := append([]FileDiff{}, r.Files...)
	sort.Slice(files, func(i, j int) bool {
		if classRank(files[i].Class) != classRank(files[j].Class) {
			return classRank(files[i].Class) < classRank(files[j].Class)
		}
		return files[i].FilePath < files[j].FilePath
	})

	labelW := 0
	pathW := 0
	for _, f := range files {
		if n := len(f.Class.String()); n > labelW {
			labelW = n
		}
		if n := len(f.FilePath); n > pathW {
			pathW = n
		}
	}

	for _, f := range files {
		renderFile(f, labelW, pathW)
	}
	if r.Truncated {
		log.Warn("stopped at the first difference, rerun without --stop-one-error for the full report")
	}
}

func renderFile(f FileDiff, labelW, pathW int) {
	detail := fileDetail(f)
	line := fmt.Sprintf("  %-*s  %-*s", labelW, f.Class.String(), pathW, f.FilePath)
	if detail != "" {
		line += "  " + detail
	}
	classLine(f.Class, trimRight(line))

	for _, o := range f.Objects {
		name := o.Name
		if name == "" {
			name = o.Kind
		}
		log.Plain("    %-9s %s  %s  %s", o.Kind, name, objectLocation(f.FilePath, o), o.Class.String())
	}

	if log.Level == log.LevelVerbose {
		if len(f.Objects) > 0 {
			for _, o := range f.Objects {
				renderHunks(o.Hunks)
			}
		} else {
			renderHunks(f.Hunks)
		}
	}
	if log.Level >= log.LevelExtreme {
		renderEdits(f.FileEdits)
	}
}

func fileDetail(f FileDiff) string {
	switch {
	case f.Class == Reordered:
		return fmt.Sprintf("deployed %d local %d", f.DeployedPos, f.LocalPos)
	case f.WhitespaceOnly:
		return "whitespace only"
	case f.Class == Changed && !f.HasBody:
		return "no stored body"
	}
	return ""
}

func classLine(c Class, line string) {
	switch c {
	case Added:
		log.Success("%s", line)
	case Dropped, Changed:
		log.Warn("%s", line)
	default:
		log.Info("%s", line)
	}
}

func classRank(c Class) int {
	switch c {
	case Added:
		return 0
	case Changed:
		return 1
	case Reordered:
		return 2
	case Dropped:
		return 3
	}
	return 4
}

func trimRight(s string) string {
	for len(s) > 0 && s[len(s)-1] == ' ' {
		s = s[:len(s)-1]
	}
	return s
}

func objectLocation(filePath string, o ObjectDiff) string {
	line := o.LocalLine
	if line == 0 {
		line = o.DeployedLine
	}
	return fmt.Sprintf("%s:%d", filePath, line)
}

func PrintDiff(prior, next string) {
	renderHunks(Hunkify(Diff(splitLines(prior), splitLines(next)), contextLines))
}

func renderHunks(hunks []Hunk) {
	for _, h := range hunks {
		log.DiffHunk(h.Header())
		for _, e := range h.Edits {
			log.DiffLine(opRune(e.Op), e.Text)
		}
	}
}

func renderEdits(edits []Edit) {
	for _, e := range edits {
		log.DiffLine(opRune(e.Op), e.Text)
	}
}

func opRune(op Op) rune {
	switch op {
	case OpInsert:
		return '+'
	case OpDelete:
		return '-'
	default:
		return ' '
	}
}

package reconcile

import (
	"fmt"

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

	rightEdge := 0
	for _, f := range r.Files {
		if w := 2 + len(f.FilePath) + 2 + len(fileLabel(f)); w > rightEdge {
			rightEdge = w
		}
	}
	for _, f := range r.Files {
		renderFile(f, rightEdge)
	}
	if r.Truncated {
		log.Warn("stopped at the first difference, rerun without --stop-one-error for the full report")
	}
}

func fileLabel(f FileDiff) string {
	switch {
	case f.WhitespaceOnly:
		return "changed whitespace only"
	case f.Class == Changed && !f.HasBody:
		return "changed no stored body"
	default:
		return f.Class.String()
	}
}

func renderFile(f FileDiff, rightEdge int) {
	log.Section(f.FilePath, fileLabel(f), rightEdge)
	if f.Class == Reordered {
		log.Plain("  position deployed %d local %d", f.DeployedPos, f.LocalPos)
	}
	for _, o := range f.Objects {
		name := o.Name
		if name == "" {
			name = o.Kind
		}
		log.Plain("  %s %s  %s  %s", o.Kind, name, objectLocation(f.FilePath, o), o.Class.String())
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

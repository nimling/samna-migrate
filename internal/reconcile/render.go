package reconcile

import (
	"github.com/nimling/samna-migrate/internal/log"
)

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

package reconcile

import (
	"fmt"
	"strings"
)

type Op int

const (
	OpEqual Op = iota
	OpInsert
	OpDelete
)

type Edit struct {
	Op   Op
	Text string
}

type Hunk struct {
	OldStart int
	OldLines int
	NewStart int
	NewLines int
	Edits    []Edit
}

func (h Hunk) Header() string {
	return fmt.Sprintf("@@ -%d,%d +%d,%d @@", h.OldStart, h.OldLines, h.NewStart, h.NewLines)
}

func splitLines(s string) []string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return []string{}
	}
	return strings.Split(s, "\n")
}

func Diff(a, b []string) []Edit {
	n, m := len(a), len(b)
	if n == 0 && m == 0 {
		return nil
	}
	maxD := n + m
	off := maxD
	v := make([]int, 2*maxD+1)
	trace := make([][]int, 0, maxD+1)
	for d := 0; d <= maxD; d++ {
		snapshot := make([]int, len(v))
		copy(snapshot, v)
		trace = append(trace, snapshot)
		for k := -d; k <= d; k += 2 {
			var x int
			if k == -d || (k != d && v[off+k-1] < v[off+k+1]) {
				x = v[off+k+1]
			} else {
				x = v[off+k-1] + 1
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x, y = x+1, y+1
			}
			v[off+k] = x
			if x >= n && y >= m {
				return backtrack(a, b, trace, off)
			}
		}
	}
	return backtrack(a, b, trace, off)
}

func backtrack(a, b []string, trace [][]int, off int) []Edit {
	var rev []Edit
	x, y := len(a), len(b)
	for d := len(trace) - 1; d >= 0; d-- {
		v := trace[d]
		k := x - y
		var prevK int
		if k == -d || (k != d && v[off+k-1] < v[off+k+1]) {
			prevK = k + 1
		} else {
			prevK = k - 1
		}
		prevX := v[off+prevK]
		prevY := prevX - prevK
		for x > prevX && y > prevY {
			rev = append(rev, Edit{OpEqual, a[x-1]})
			x, y = x-1, y-1
		}
		if d > 0 {
			if x == prevX {
				rev = append(rev, Edit{OpInsert, b[y-1]})
				y--
			} else {
				rev = append(rev, Edit{OpDelete, a[x-1]})
				x--
			}
		}
	}
	for i, j := 0, len(rev)-1; i < j; i, j = i+1, j-1 {
		rev[i], rev[j] = rev[j], rev[i]
	}
	return rev
}

func Hunkify(edits []Edit, context int) []Hunk {
	n := len(edits)
	if n == 0 {
		return nil
	}
	oldNo := make([]int, n)
	newNo := make([]int, n)
	o, ne := 1, 1
	changed := false
	for i, e := range edits {
		oldNo[i] = o
		newNo[i] = ne
		switch e.Op {
		case OpEqual:
			o++
			ne++
		case OpDelete:
			o++
			changed = true
		case OpInsert:
			ne++
			changed = true
		}
	}
	if !changed {
		return nil
	}
	inHunk := make([]bool, n)
	for i, e := range edits {
		if e.Op == OpEqual {
			continue
		}
		lo := i - context
		if lo < 0 {
			lo = 0
		}
		hi := i + context
		if hi >= n {
			hi = n - 1
		}
		for j := lo; j <= hi; j++ {
			inHunk[j] = true
		}
	}
	var hunks []Hunk
	i := 0
	for i < n {
		if !inHunk[i] {
			i++
			continue
		}
		j := i
		for j < n && inHunk[j] {
			j++
		}
		seg := edits[i:j]
		h := Hunk{OldStart: oldNo[i], NewStart: newNo[i], Edits: seg}
		for _, e := range seg {
			switch e.Op {
			case OpEqual:
				h.OldLines++
				h.NewLines++
			case OpDelete:
				h.OldLines++
			case OpInsert:
				h.NewLines++
			}
		}
		hunks = append(hunks, h)
		i = j
	}
	return hunks
}

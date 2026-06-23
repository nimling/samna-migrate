package reconcile

import "testing"

func countOps(edits []Edit) (eq, ins, del int) {
	for _, e := range edits {
		switch e.Op {
		case OpEqual:
			eq++
		case OpInsert:
			ins++
		case OpDelete:
			del++
		}
	}
	return
}

func TestDiffIdentical(t *testing.T) {
	a := []string{"one", "two", "three"}
	edits := Diff(a, a)
	eq, ins, del := countOps(edits)
	if ins != 0 || del != 0 {
		t.Fatalf("identical inputs produced changes: ins=%d del=%d", ins, del)
	}
	if eq != 3 {
		t.Fatalf("expected 3 equal edits, got %d", eq)
	}
	if h := Hunkify(edits, 3); h != nil {
		t.Fatalf("identical inputs produced %d hunks, want none", len(h))
	}
}

func TestDiffInsertDelete(t *testing.T) {
	a := []string{"a", "b", "c"}
	b := []string{"a", "x", "c"}
	edits := Diff(a, b)
	_, ins, del := countOps(edits)
	if ins != 1 || del != 1 {
		t.Fatalf("expected one insert and one delete, got ins=%d del=%d", ins, del)
	}
}

func TestDiffReconstructsTarget(t *testing.T) {
	a := []string{"keep", "drop1", "drop2", "tail"}
	b := []string{"keep", "add1", "tail", "add2"}
	edits := Diff(a, b)
	var got []string
	for _, e := range edits {
		if e.Op == OpEqual || e.Op == OpInsert {
			got = append(got, e.Text)
		}
	}
	if len(got) != len(b) {
		t.Fatalf("reconstructed length %d, want %d", len(got), len(b))
	}
	for i := range b {
		if got[i] != b[i] {
			t.Fatalf("reconstructed[%d]=%q, want %q", i, got[i], b[i])
		}
	}
}

func TestHunkifyHeader(t *testing.T) {
	a := []string{"l1", "l2", "l3", "l4", "l5"}
	b := []string{"l1", "l2", "CHANGED", "l4", "l5"}
	hunks := Hunkify(Diff(a, b), 1)
	if len(hunks) != 1 {
		t.Fatalf("expected 1 hunk, got %d", len(hunks))
	}
	if hunks[0].Header() == "" {
		t.Fatalf("hunk header is empty")
	}
}

func TestSplitLines(t *testing.T) {
	if got := splitLines(""); len(got) != 0 {
		t.Fatalf("empty string split to %d lines", len(got))
	}
	if got := splitLines("a\nb\n"); len(got) != 2 {
		t.Fatalf("trailing newline produced %d lines, want 2", len(got))
	}
}

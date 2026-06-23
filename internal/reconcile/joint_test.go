package reconcile

import "testing"

func TestColumnChanges(t *testing.T) {
	live := "a integer\nb text\nc uuid not null"
	built := "a integer\nc uuid\nd jsonb"
	cc := columnChanges(live, built)
	got := map[string]string{}
	for _, c := range cc {
		got[c.Name] = c.Change
	}
	if got["d"] != "add" {
		t.Fatalf("expected d add, got %v", got)
	}
	if got["b"] != "drop" {
		t.Fatalf("expected b drop, got %v", got)
	}
	if got["c"] != "alter" {
		t.Fatalf("expected c alter, got %v", got)
	}
	if _, ok := got["a"]; ok {
		t.Fatalf("unchanged column a should not appear, got %v", got)
	}
}

func TestColumnOrderInsensitive(t *testing.T) {
	if len(columnChanges("a int\nb text", "b text\na int")) != 0 {
		t.Fatalf("reordered columns must not be a difference")
	}
}

func TestExcludeNonCreateStatements(t *testing.T) {
	dep := map[string]string{}
	loc := map[string]string{"a.sql": "CREATE TABLE public.t (id int);\nDROP FUNCTION public.old();\nALTER TABLE public.t ADD COLUMN x int;"}
	rep := analyzeObjects(dep, loc)
	for _, c := range rep.Changes {
		if c.Kind == "drop" || c.Kind == "alter" {
			t.Fatalf("non-create statement leaked into object index: %s %s", c.Kind, c.Name)
		}
	}
	if reasonsFor(rep, "table", "public.t") == nil {
		t.Fatalf("expected the created table to be tracked")
	}
}

func TestDedupeReasons(t *testing.T) {
	out := dedupe([]string{"added", "added", "content", "added"})
	if len(out) != 2 || out[0] != "added" || out[1] != "content" {
		t.Fatalf("dedupe kept duplicates or lost order: %v", out)
	}
}

func TestRemediationReviewOnIncompleteBuild(t *testing.T) {
	jo := &JointObj{Reasons: []string{"only in live"}}
	if got := remediation(jo, true, false); got != "review" {
		t.Fatalf("incomplete build only-in-live should be review, got %q", got)
	}
	if got := remediation(jo, true, true); got != "drop" {
		t.Fatalf("complete build only-in-live should be drop, got %q", got)
	}
}

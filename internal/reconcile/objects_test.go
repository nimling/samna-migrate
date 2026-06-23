package reconcile

import (
	"fmt"
	"testing"
)

func reasonsFor(rep *ObjReport, kind, name string) []string {
	for _, c := range rep.Changes {
		if c.Kind == kind && (c.Name == name || c.OldName == name) {
			return c.Reasons
		}
	}
	return nil
}

func hasReason(rs []string, want string) bool {
	for _, r := range rs {
		if r == want {
			return true
		}
	}
	return false
}

func TestObjectMoved(t *testing.T) {
	fn := "CREATE OR REPLACE FUNCTION public.foo() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;"
	dep := map[string]string{"a.sql": fn}
	loc := map[string]string{"b.sql": fn}
	rep := analyzeObjects(dep, loc)
	rs := reasonsFor(rep, "function", "public.foo")
	if !hasReason(rs, "moved") {
		t.Fatalf("expected moved, got %v", rs)
	}
}

func TestObjectContentChanged(t *testing.T) {
	dep := map[string]string{"a.sql": "CREATE OR REPLACE FUNCTION public.foo() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;"}
	loc := map[string]string{"a.sql": "CREATE OR REPLACE FUNCTION public.foo() RETURNS int LANGUAGE sql AS $$ SELECT 2 $$;"}
	rep := analyzeObjects(dep, loc)
	rs := reasonsFor(rep, "function", "public.foo")
	if !hasReason(rs, "content") {
		t.Fatalf("expected content, got %v", rs)
	}
}

func TestObjectSignatureChanged(t *testing.T) {
	dep := map[string]string{"a.sql": "CREATE OR REPLACE FUNCTION public.foo(a int) RETURNS int LANGUAGE sql AS $$ SELECT a $$;"}
	loc := map[string]string{"a.sql": "CREATE OR REPLACE FUNCTION public.foo(a int, b int) RETURNS int LANGUAGE sql AS $$ SELECT a $$;"}
	rep := analyzeObjects(dep, loc)
	rs := reasonsFor(rep, "function", "public.foo")
	if !hasReason(rs, "signature") {
		t.Fatalf("expected signature, got %v", rs)
	}
}

func TestObjectAddedDeleted(t *testing.T) {
	dep := map[string]string{"a.sql": "CREATE TABLE public.gone (id int);"}
	loc := map[string]string{"a.sql": "CREATE TABLE public.fresh (id int);"}
	rep := analyzeObjects(dep, loc)
	if rs := reasonsFor(rep, "table", "public.gone"); !hasReason(rs, "deleted") {
		t.Fatalf("expected deleted for gone, got %v", rs)
	}
	if rs := reasonsFor(rep, "table", "public.fresh"); !hasReason(rs, "added") {
		t.Fatalf("expected added for fresh, got %v", rs)
	}
}

func TestObjectRenamed(t *testing.T) {
	body := "CREATE OR REPLACE FUNCTION public.%s() RETURNS int LANGUAGE sql AS $$\nSELECT 1\nUNION SELECT 2\nUNION SELECT 3\n$$;"
	dep := map[string]string{"a.sql": fmt.Sprintf(body, "old_name")}
	loc := map[string]string{"a.sql": fmt.Sprintf(body, "new_name")}
	rep := analyzeObjects(dep, loc)
	rs := reasonsFor(rep, "function", "public.old_name")
	if !hasReason(rs, "renamed") {
		t.Fatalf("expected renamed, got changes %+v", rep.Changes)
	}
}


func TestSimilarity(t *testing.T) {
	if similar("a\nb\nc\nd", "a\nb\nc\nd") != 1 {
		t.Fatalf("identical bodies should be fully similar")
	}
	if similar("a\nb\nc\nd", "w\nx\ny\nz") != 0 {
		t.Fatalf("disjoint bodies should be zero similar")
	}
}

package reconcile

import "testing"

func fileClass(r *Report, path string) Class {
	for _, f := range r.Files {
		if f.FilePath == path {
			return f.Class
		}
	}
	return Same
}

func TestBuildReportClassifies(t *testing.T) {
	local := map[string]LocalFile{
		"base/a.sql": {FilePath: "base/a.sql", Position: 1, Sha256: "sha-a", Content: "SELECT 1;"},
		"base/b.sql": {FilePath: "base/b.sql", Position: 2, Sha256: "sha-b-new", Content: "SELECT 2;"},
		"base/c.sql": {FilePath: "base/c.sql", Position: 3, Sha256: "sha-c", Content: "SELECT 3;"},
	}
	deployed := map[string]DeployedFile{
		"base/b.sql": {FilePath: "base/b.sql", AppliedPosition: 2, State: "applied", AppliedSha256: "sha-b-old", AppliedSQL: "SELECT 1;", HasSQL: true},
		"base/c.sql": {FilePath: "base/c.sql", AppliedPosition: 3, State: "applied", AppliedSha256: "sha-c", AppliedSQL: "SELECT 3;", HasSQL: true},
		"base/d.sql": {FilePath: "base/d.sql", AppliedPosition: 4, State: "applied", AppliedSha256: "sha-d", AppliedSQL: "SELECT 4;", HasSQL: true},
	}
	r := buildReport(local, deployed, false)

	if c := fileClass(r, "base/a.sql"); c != Added {
		t.Fatalf("a.sql class=%s, want added", c)
	}
	if c := fileClass(r, "base/b.sql"); c != Changed {
		t.Fatalf("b.sql class=%s, want changed", c)
	}
	if c := fileClass(r, "base/d.sql"); c != Dropped {
		t.Fatalf("d.sql class=%s, want dropped", c)
	}
	if r.Same != 1 {
		t.Fatalf("expected 1 same file, got %d", r.Same)
	}
	if r.Added != 1 || r.Changed != 1 || r.Dropped != 1 {
		t.Fatalf("counts added=%d changed=%d dropped=%d", r.Added, r.Changed, r.Dropped)
	}
}

func TestBuildReportReordered(t *testing.T) {
	local := map[string]LocalFile{
		"a.sql": {FilePath: "a.sql", Position: 1, Sha256: "sa", Content: "x"},
		"b.sql": {FilePath: "b.sql", Position: 2, Sha256: "sb", Content: "y"},
	}
	deployed := map[string]DeployedFile{
		"a.sql": {FilePath: "a.sql", AppliedPosition: 2, State: "applied", AppliedSha256: "sa", AppliedSQL: "x", HasSQL: true},
		"b.sql": {FilePath: "b.sql", AppliedPosition: 1, State: "applied", AppliedSha256: "sb", AppliedSQL: "y", HasSQL: true},
	}
	r := buildReport(local, deployed, false)
	if r.Reordered != 2 {
		t.Fatalf("expected 2 reordered files, got %d", r.Reordered)
	}
}

func TestBuildReportStopOnError(t *testing.T) {
	local := map[string]LocalFile{
		"a.sql": {FilePath: "a.sql", Position: 1, Sha256: "sa", Content: "x"},
		"b.sql": {FilePath: "b.sql", Position: 2, Sha256: "sb", Content: "y"},
	}
	deployed := map[string]DeployedFile{}
	r := buildReport(local, deployed, true)
	if !r.Truncated {
		t.Fatalf("expected truncated report under stopOnError")
	}
	if len(r.Files) != 1 {
		t.Fatalf("expected 1 file before stop, got %d", len(r.Files))
	}
}

func TestDiffObjectsPinpointsFunction(t *testing.T) {
	deployed := "CREATE TABLE public.bar (id int);\nCREATE OR REPLACE FUNCTION public.foo() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$;"
	local := "CREATE TABLE public.bar (id int);\nCREATE OR REPLACE FUNCTION public.foo() RETURNS int LANGUAGE sql AS $$ SELECT 2 $$;"
	diffs := diffObjects(deployed, local)
	if len(diffs) != 1 {
		t.Fatalf("expected 1 object diff, got %d", len(diffs))
	}
	o := diffs[0]
	if o.Class != Changed || o.Kind != "function" || o.Name != "public.foo" {
		t.Fatalf("unexpected object diff: class=%s kind=%s name=%s", o.Class, o.Kind, o.Name)
	}
	if o.DeployedLine == 0 || o.LocalLine == 0 {
		t.Fatalf("expected both source lines set, got deployed=%d local=%d", o.DeployedLine, o.LocalLine)
	}
}

func TestWhitespaceOnly(t *testing.T) {
	if !whitespaceOnly("a  \nb", "a\nb") {
		t.Fatalf("trailing whitespace difference should be whitespace only")
	}
	if whitespaceOnly("a", "b") {
		t.Fatalf("content difference flagged as whitespace only")
	}
}

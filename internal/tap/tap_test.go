package tap

import (
	"strings"
	"testing"
)

func lines(s string) []string {
	return strings.Split(strings.TrimSpace(s), "\n")
}

func TestParseCleanRun(t *testing.T) {
	r := Parse(lines(`
1..3
ok 1 - table exists
ok 2 - function exists
# a diagnostic line
ok 3 - rows match
`))
	if r.Plan != 3 || r.Ok != 3 || r.NotOk != 0 || r.Missing != 0 || r.BailOut {
		t.Fatalf("clean run parsed as %+v", r)
	}
	if !r.Passed() {
		t.Fatalf("clean run did not pass: %+v", r)
	}
}

func TestParseFailureAndDiag(t *testing.T) {
	r := Parse(lines(`
1..2
ok 1 - first
not ok 2 - second
# Failed test 2: "second"
#         have: 1
#         want: 2
`))
	if r.Plan != 2 || r.Ok != 1 || r.NotOk != 1 {
		t.Fatalf("failure parsed as %+v", r)
	}
	if len(r.Failures) != 1 || r.Failures[0] != "not ok 2 - second" {
		t.Fatalf("failures = %#v", r.Failures)
	}
	if r.Passed() {
		t.Fatalf("failing run passed: %+v", r)
	}
}

func TestParseMissingTests(t *testing.T) {
	r := Parse(lines(`
1..3
ok 1 - only one
`))
	if r.Missing != 2 || r.Passed() {
		t.Fatalf("short run parsed as %+v", r)
	}
	r = Parse(lines(`
1..1
ok 1 - one
ok 2 - two
`))
	if r.Missing != 1 || r.Passed() {
		t.Fatalf("over run parsed as %+v", r)
	}
}

func TestParseNoPlan(t *testing.T) {
	r := Parse(lines(`
ok 1 - orphan
`))
	if r.Plan != 0 || r.Passed() {
		t.Fatalf("unplanned run parsed as %+v", r)
	}
}

func TestParseBailOut(t *testing.T) {
	r := Parse(lines(`
1..2
ok 1 - first
Bail out! relation "missing" does not exist
`))
	if !r.BailOut || r.Passed() {
		t.Fatalf("bail out parsed as %+v", r)
	}
	if len(r.Failures) != 1 || !strings.HasPrefix(r.Failures[0], "Bail out!") {
		t.Fatalf("failures = %#v", r.Failures)
	}
}

func TestLineClasses(t *testing.T) {
	if !IsDiag("  # note") || IsDiag("ok 1") {
		t.Fatal("IsDiag misclassified")
	}
	if !IsFailure("not ok 3 - x") || !IsFailure("Bail out! boom") || IsFailure("ok 3 - x") {
		t.Fatal("IsFailure misclassified")
	}
}

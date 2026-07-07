package migrate

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/steps"
)

func TestDownRequiresKey(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "")
	downCmd.SetContext(context.Background())
	cmd := downCmd
	cmd.SetArgs([]string{"--to", "x.sql"})
	err := cmd.RunE(cmd, []string{})
	if err == nil || !strings.Contains(err.Error(), "ANTHROPIC_API_KEY") {
		t.Errorf("expected missing key error, got %v", err)
	}
}

func TestDownRequiresTarget(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "fake")
	downCmd.SetContext(context.Background())
	downTo, downSteps, downDryRun = "", 0, false
	err := downCmd.RunE(downCmd, []string{})
	if err == nil || !strings.Contains(err.Error(), "--to") {
		t.Errorf("expected target requirement, got %v", err)
	}
}

func TestGroupPendingOrdersByStepAndVersion(t *testing.T) {
	dir := t.TempDir()
	baseDir := filepath.Join(dir, "base")
	systemDir := filepath.Join(dir, "system")
	for _, d := range []string{baseDir, systemDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"V1.2__base_two.sql", "V1.9__base_nine.sql", "V1.10__base_ten.sql", "V1.11__base_eleven.sql"} {
		if err := os.WriteFile(filepath.Join(baseDir, f), []byte("SELECT 1;"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(systemDir, "V2.0__system_init.sql"), []byte("SELECT 1;"), 0o644); err != nil {
		t.Fatal(err)
	}

	stepsCfg := &steps.Config{Steps: []steps.Step{
		{Name: "Migrations", Type: "migration", Include: []steps.IncludeEntry{{Path: "base"}}},
		{Name: "System", Type: "seed", Slug: "system", Include: []steps.IncludeEntry{{Path: "system"}}},
	}}

	pendings := []apply.Pending{
		{FilePath: "system/V2.0__system_init.sql", FileName: "V2.0__system_init.sql", Position: 5},
		{FilePath: "base/V1.11__base_eleven.sql", FileName: "V1.11__base_eleven.sql", Position: 20},
		{FilePath: "base/V1.10__base_ten.sql", FileName: "V1.10__base_ten.sql", Position: 19},
		{FilePath: "base/V1.9__base_nine.sql", FileName: "V1.9__base_nine.sql", Position: 2},
	}

	groups, err := groupPending(pendings, stepsCfg, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(groups))
	}
	if groups[0].name != "Migrations" || groups[1].name != "System" {
		t.Fatalf("groups out of step order: %s, %s", groups[0].name, groups[1].name)
	}
	got := []string{}
	for _, p := range groups[0].files {
		got = append(got, p.FileName)
	}
	want := []string{"V1.9__base_nine.sql", "V1.10__base_ten.sql", "V1.11__base_eleven.sql"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("file order mismatch at %d: got %v want %v", i, got, want)
		}
	}
	if groups[1].files[0].FileName != "V2.0__system_init.sql" {
		t.Fatalf("system group file mismatch: %s", groups[1].files[0].FileName)
	}
}

func sampleOrdered() []orderedPending {
	claimius := &pendingGroup{name: "Claimius Schema", st: &steps.Step{Type: "base", Slug: "claimius"}, files: []apply.Pending{
		{FileName: "V3.0__claimius_triggers.sql", FilePath: "claimius/V3.0__claimius_triggers.sql"},
		{FileName: "V3.1__claimius_sync_event.sql", FilePath: "claimius/V3.1__claimius_sync_event.sql"},
	}}
	migrations := &pendingGroup{name: "Migrations", st: &steps.Step{Type: "migration"}, files: []apply.Pending{
		{FileName: "V1.0__claimius_sync_event_notify.sql", FilePath: "migrations/V1.0__claimius_sync_event_notify.sql"},
		{FileName: "V1.1__public_booking_index.sql", FilePath: "migrations/V1.1__public_booking_index.sql"},
	}}
	system := &pendingGroup{name: "System", st: &steps.Step{Type: "base", Slug: "system"}, files: []apply.Pending{
		{FileName: "V2.0__system_init.sql", FilePath: "system/V2.0__system_init.sql"},
	}}
	return flatten([]*pendingGroup{claimius, migrations, system})
}

func TestFlattenPreservesOrder(t *testing.T) {
	ordered := sampleOrdered()
	want := []string{
		"V3.0__claimius_triggers.sql",
		"V3.1__claimius_sync_event.sql",
		"V1.0__claimius_sync_event_notify.sql",
		"V1.1__public_booking_index.sql",
		"V2.0__system_init.sql",
	}
	if len(ordered) != len(want) {
		t.Fatalf("expected %d entries, got %d", len(want), len(ordered))
	}
	for i := range want {
		if ordered[i].p.FileName != want[i] {
			t.Fatalf("order mismatch at %d: got %s want %s", i, ordered[i].p.FileName, want[i])
		}
	}
}

func TestResolveTarget(t *testing.T) {
	ordered := sampleOrdered()
	cases := []struct {
		target string
		want   int
	}{
		{"", 4},
		{"all", 4},
		{"ALL", 4},
		{"1", 0},
		{"3", 2},
		{"5", 4},
		{"claimius:3.0", 0},
		{"claimius:3.1", 1},
		{"claimius:1.0", 2},
		{"public:1.1", 3},
		{"system:2.0", 4},
		{"claimius", 1},
		{"system", 4},
	}
	for _, c := range cases {
		got, err := resolveTarget(c.target, ordered)
		if err != nil {
			t.Fatalf("resolveTarget(%q) error: %v", c.target, err)
		}
		if got != c.want {
			t.Fatalf("resolveTarget(%q) = %d, want %d", c.target, got, c.want)
		}
	}
}

func TestResolveTargetErrors(t *testing.T) {
	ordered := sampleOrdered()
	for _, target := range []string{"0", "6", "claimius:9.9", "public:2.0", "nope"} {
		if _, err := resolveTarget(target, ordered); err == nil {
			t.Fatalf("resolveTarget(%q) expected error, got nil", target)
		}
	}
}

func TestGroupCountWithin(t *testing.T) {
	ordered := sampleOrdered()
	claimius := ordered[0].g
	migrations := ordered[2].g
	system := ordered[4].g
	if n := groupCountWithin(ordered, claimius, 4); n != 2 {
		t.Fatalf("claimius within full = %d, want 2", n)
	}
	if n := groupCountWithin(ordered, migrations, 2); n != 1 {
		t.Fatalf("migrations within limit 2 = %d, want 1", n)
	}
	if n := groupCountWithin(ordered, system, 2); n != 0 {
		t.Fatalf("system within limit 2 = %d, want 0", n)
	}
}

func TestRenderList(t *testing.T) {
	out := renderList(sampleOrdered())
	for _, want := range []string{
		"▸ Claimius Schema",
		"slug=claimius",
		"▸ Migrations",
		"type=migration",
		"  1  V3.0__claimius_triggers.sql",
		"claimius:3.0",
		"  5  V2.0__system_init.sql",
		"system:2.0",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("renderList missing %q in:\n%s", want, out)
		}
	}
}

func TestPromptTarget(t *testing.T) {
	ordered := sampleOrdered()

	limit, tok, err := promptTarget(strings.NewReader("3\n"), ordered)
	if err != nil || limit != 2 || tok != "3" {
		t.Fatalf("direct pick got limit=%d tok=%q err=%v", limit, tok, err)
	}

	limit, tok, err = promptTarget(strings.NewReader("bogus\n2\n"), ordered)
	if err != nil || limit != 1 || tok != "2" {
		t.Fatalf("retry pick got limit=%d tok=%q err=%v", limit, tok, err)
	}

	if _, _, err := promptTarget(strings.NewReader(""), ordered); err == nil {
		t.Fatalf("empty input expected error, got nil")
	}
}

func TestSelectTargets(t *testing.T) {
	ordered := sampleOrdered()
	cases := []struct {
		target string
		want   []int
	}{
		{"3", []int{2}},
		{"1", []int{0}},
		{"claimius:1.0", []int{2}},
		{"public:1.1", []int{3}},
		{"system:2.0", []int{4}},
		{"claimius", []int{0, 1}},
		{"system", []int{4}},
	}
	for _, c := range cases {
		got, err := selectTargets(c.target, ordered)
		if err != nil {
			t.Fatalf("selectTargets(%q) error: %v", c.target, err)
		}
		if len(got) != len(c.want) {
			t.Fatalf("selectTargets(%q) = %v, want %v", c.target, got, c.want)
		}
		for i := range c.want {
			if got[i] != c.want[i] {
				t.Fatalf("selectTargets(%q) = %v, want %v", c.target, got, c.want)
			}
		}
	}
}

func TestSelectTargetsErrors(t *testing.T) {
	ordered := sampleOrdered()
	for _, target := range []string{"", "0", "6", "claimius:9.9", "public:2.0", "nope"} {
		if _, err := selectTargets(target, ordered); err == nil {
			t.Fatalf("selectTargets(%q) expected error, got nil", target)
		}
	}
}

func TestPromptRun(t *testing.T) {
	ordered := sampleOrdered()

	idxs, tok, err := promptRun(strings.NewReader("claimius\n"), ordered)
	if err != nil || tok != "claimius" || len(idxs) != 2 || idxs[0] != 0 || idxs[1] != 1 {
		t.Fatalf("step pick got idxs=%v tok=%q err=%v", idxs, tok, err)
	}

	idxs, tok, err = promptRun(strings.NewReader("bogus\n3\n"), ordered)
	if err != nil || tok != "3" || len(idxs) != 1 || idxs[0] != 2 {
		t.Fatalf("retry pick got idxs=%v tok=%q err=%v", idxs, tok, err)
	}

	if _, _, err := promptRun(strings.NewReader(""), ordered); err == nil {
		t.Fatalf("empty input expected error, got nil")
	}
}

func TestSelectTargetsByNameAndPath(t *testing.T) {
	ordered := sampleOrdered()
	cases := []struct {
		target string
		want   int
	}{
		{"V3.0__claimius_triggers.sql", 0},
		{"V1.1__public_booking_index.sql", 3},
		{"V2.0__system_init.sql", 4},
		{"claimius/V3.1__claimius_sync_event.sql", 1},
		{"migrations/V1.0__claimius_sync_event_notify.sql", 2},
	}
	for _, c := range cases {
		got, err := selectTargets(c.target, ordered)
		if err != nil {
			t.Fatalf("selectTargets(%q) error: %v", c.target, err)
		}
		if len(got) != 1 || got[0] != c.want {
			t.Fatalf("selectTargets(%q) = %v, want [%d]", c.target, got, c.want)
		}
	}
}

func TestResolvePath(t *testing.T) {
	root := t.TempDir()
	dbDir := filepath.Join(root, "database")
	yamlDir := filepath.Join(root, "cfg")
	outside := filepath.Join(root, "outside")
	for _, d := range []string{dbDir, yamlDir, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	inDB := filepath.Join(dbDir, "patch.sql")
	inYaml := filepath.Join(yamlDir, "cfgpatch.sql")
	ext := filepath.Join(outside, "hotfix.sql")
	for _, f := range []string{inDB, inYaml, ext} {
		if err := os.WriteFile(f, []byte("SELECT 1;"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	stepsFile := filepath.Join(yamlDir, "migrate.yml")

	if got, ok := resolvePath("patch.sql", dbDir, stepsFile); !ok || got != inDB {
		t.Fatalf("db-dir relative got %q ok=%v want %q", got, ok, inDB)
	}
	if got, ok := resolvePath("cfgpatch.sql", dbDir, stepsFile); !ok || got != inYaml {
		t.Fatalf("yaml-dir relative got %q ok=%v want %q", got, ok, inYaml)
	}
	if got, ok := resolvePath(ext, dbDir, stepsFile); !ok || got != ext {
		t.Fatalf("absolute got %q ok=%v want %q", got, ok, ext)
	}
	if _, ok := resolvePath("nope.sql", dbDir, stepsFile); ok {
		t.Fatalf("missing path expected not ok")
	}
}

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

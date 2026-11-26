//go:build e2e

package e2e

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSmigDumpInsertRoundtrip(t *testing.T) {
	p := dial(t)
	defer p.Close()
	ctx := context.Background()

	if _, err := p.Exec(ctx, `DROP TABLE IF EXISTS public.smig_e2e_dump`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Exec(ctx, `CREATE TABLE public.smig_e2e_dump (id int, label text)`); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Exec(ctx, `INSERT INTO public.smig_e2e_dump VALUES (1, 'one'), (2, 'two')`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { p.Exec(context.Background(), `DROP TABLE IF EXISTS public.smig_e2e_dump`) })

	dir := t.TempDir()
	stdout, stderr, err := runSmig(t, "dump", "--table=public.smig_e2e_dump", "--out="+dir)
	if err != nil {
		t.Fatalf("smig dump failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	file := filepath.Join(dir, "public.smig_e2e_dump.json")
	body, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("dump file missing: %v", err)
	}
	if !strings.Contains(string(body), "one") {
		t.Errorf("dump body missing row data: %s", body)
	}

	if _, err := p.Exec(ctx, `TRUNCATE public.smig_e2e_dump`); err != nil {
		t.Fatal(err)
	}
	stdout, stderr, err = runSmig(t, "insert", file)
	if err != nil {
		t.Fatalf("smig insert failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}

	var n int
	if err := p.QueryRow(ctx, `SELECT count(*) FROM public.smig_e2e_dump`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("row count after insert = %d, want 2", n)
	}
}

func TestSmigInsertModesPlanAndFormats(t *testing.T) {
	p := dial(t)
	defer p.Close()
	ctx := context.Background()
	for _, q := range []string{
		`DROP TABLE IF EXISTS public.smig_e2e_modes`,
		`CREATE TABLE public.smig_e2e_modes (id int PRIMARY KEY, label text, sa_owner_id int)`,
		`INSERT INTO public.smig_e2e_modes VALUES (1, 'one', 7), (2, 'two', 8)`,
	} {
		if _, err := p.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { p.Exec(context.Background(), `DROP TABLE IF EXISTS public.smig_e2e_modes`) })

	dir := t.TempDir()
	if stdout, stderr, err := runSmig(t, "dump", "--table=public.smig_e2e_modes", "--format=jsonl", "--out="+dir); err != nil {
		t.Fatalf("smig dump --format=jsonl failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	body, err := os.ReadFile(filepath.Join(dir, "public.smig_e2e_modes.jsonl"))
	if err != nil {
		t.Fatalf("jsonl dump missing: %v", err)
	}
	if lines := strings.Count(strings.TrimSpace(string(body)), "\n") + 1; lines != 2 {
		t.Errorf("jsonl dump has %d lines, want 2:\n%s", lines, body)
	}

	partial := filepath.Join(t.TempDir(), "public.smig_e2e_modes.jsonl")
	if err := os.WriteFile(partial, []byte(`{"id":1,"label":"uno"}`+"\n"+`{"id":3,"label":"three"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, stderr, err := runSmig(t, "insert", partial)
	if code := exitCode(err); code != 3 {
		t.Fatalf("insert over an existing key exit = %d, want 3\nstderr: %s", code, stderr)
	}
	if !strings.Contains(stderr, "line 1") || !strings.Contains(stderr, "id=1") {
		t.Errorf("refusal does not name the line and key: %s", stderr)
	}

	stdout, stderr, err := runSmig(t, "insert", partial, "--mode=merge", "--plan", "--json")
	if err != nil {
		t.Fatalf("smig insert --plan --json failed: %v\nstderr: %s", err, stderr)
	}
	var plan []map[string]any
	if err := json.Unmarshal([]byte(stdout), &plan); err != nil {
		t.Fatalf("plan json does not parse: %v\n%s", err, stdout)
	}
	if len(plan) != 1 || plan[0]["inserted"] != float64(1) || plan[0]["updated"] != float64(1) || plan[0]["plan"] != true {
		t.Errorf("plan json = %v", plan)
	}

	if _, _, err := runSmig(t, "insert", partial, "--mode=merge"); err != nil {
		t.Fatalf("smig insert --mode=merge failed: %v", err)
	}
	var label string
	var owner int
	if err := p.QueryRow(ctx, `SELECT label, sa_owner_id FROM public.smig_e2e_modes WHERE id = 1`).Scan(&label, &owner); err != nil {
		t.Fatal(err)
	}
	if label != "uno" || owner != 7 {
		t.Errorf("merged row = %q %d, want uno 7", label, owner)
	}

	if _, _, err := runSmig(t, "insert", partial, "--mode=sync"); exitCode(err) != 2 {
		t.Errorf("an unknown mode exit = %d, want 2", exitCode(err))
	}
}

func exitCode(err error) int {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		return exit.ExitCode()
	}
	if err != nil {
		return -1
	}
	return 0
}

func TestSmigDestroyDryRunDropsNothing(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not present, destroy needs it to build the candidate")
	}
	p := dial(t)
	defer p.Close()
	ctx := context.Background()

	stdout, stderr, err := runSmig(t, "destroy", "--dry-run")
	if err != nil {
		t.Fatalf("smig destroy --dry-run failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	combined := stdout + stderr
	if !strings.Contains(combined, "destroy plan") {
		t.Errorf("expected destroy plan header: %s", combined)
	}
	if !strings.Contains(combined, "dry run") {
		t.Errorf("expected dry run marker: %s", combined)
	}
	if !strings.Contains(combined, "DROP SCHEMA samna_migrate CASCADE") {
		t.Errorf("expected samna_migrate ledger drop in plan: %s", combined)
	}

	var n int
	if err := p.QueryRow(ctx, `
		SELECT count(*) FROM information_schema.tables
		WHERE table_schema = 'public' AND table_name = 'bookable'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("public.bookable dropped by dry run, count = %d", n)
	}
}

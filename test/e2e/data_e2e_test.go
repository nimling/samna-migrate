//go:build e2e

package e2e

import (
	"context"
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

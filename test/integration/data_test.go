//go:build integration

package integration

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/testdb"
)

func TestDumpInsertRoundtrip(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if _, err := d.Pool.Exec(ctx, `
		CREATE TABLE public.smig_roundtrip (
			id uuid DEFAULT gen_random_uuid(),
			n int,
			label text,
			meta jsonb,
			flag bool,
			amount numeric,
			at timestamptz
		)`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `
		INSERT INTO public.smig_roundtrip (n, label, meta, flag, amount, at) VALUES
		    (1, 'alpha', '{"k":1}'::jsonb, true, 1.25, '2026-01-02T03:04:05Z'),
		    (2, 'beta',  '{"k":[1,2]}'::jsonb, false, 9.99, '2026-06-07T08:09:10Z')`); err != nil {
		t.Fatal(err)
	}

	tbl := data.Table{Schema: "public", Name: "smig_roundtrip"}
	dir := t.TempDir()
	count, path, err := data.DumpTable(ctx, d, tbl, dir)
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("dumped count = %d, want 2", count)
	}
	if filepath.Base(path) != "public.smig_roundtrip.json" {
		t.Errorf("dump path = %q", path)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("dump file missing: %v", err)
	}

	if _, err := d.Pool.Exec(ctx, `TRUNCATE public.smig_roundtrip`); err != nil {
		t.Fatal(err)
	}
	rows, err := data.InsertFile(ctx, d, tbl, path, false)
	if err != nil {
		t.Fatal(err)
	}
	if rows != 2 {
		t.Fatalf("inserted rows = %d, want 2", rows)
	}

	var n int
	var sum float64
	if err := d.Pool.QueryRow(ctx, `SELECT count(*), COALESCE(sum(amount),0) FROM public.smig_roundtrip`).Scan(&n, &sum); err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Errorf("row count after reinsert = %d, want 2", n)
	}
	if sum < 11.23 || sum > 11.25 {
		t.Errorf("amount sum after reinsert = %v, want 11.24", sum)
	}

	var meta string
	if err := d.Pool.QueryRow(ctx, `SELECT meta->>'k' FROM public.smig_roundtrip WHERE label = 'alpha'`).Scan(&meta); err != nil {
		t.Fatal(err)
	}
	if meta != "1" {
		t.Errorf("jsonb roundtrip meta.k = %q, want 1", meta)
	}
}

func TestInsertNoTriggersBypassesTrigger(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if _, err := d.Pool.Exec(ctx, `CREATE TABLE public.smig_guard (id int)`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `
		CREATE OR REPLACE FUNCTION public.smig_guard_block() RETURNS trigger
		LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'blocked'; END; $$`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `
		CREATE TRIGGER tg_smig_guard BEFORE INSERT ON public.smig_guard
		FOR EACH ROW EXECUTE FUNCTION public.smig_guard_block()`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		d.Pool.Exec(context.Background(), `DROP FUNCTION IF EXISTS public.smig_guard_block() CASCADE`)
	})

	dir := t.TempDir()
	path := filepath.Join(dir, "public.smig_guard.json")
	if err := os.WriteFile(path, []byte(`[{"id":1},{"id":2}]`), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := data.InsertFile(ctx, d, data.Table{Schema: "public", Name: "smig_guard"}, path, false); err == nil {
		t.Fatal("insert with triggers enabled should have been blocked")
	}

	rows, err := data.InsertFile(ctx, d, data.Table{Schema: "public", Name: "smig_guard"}, path, true)
	if err != nil {
		t.Fatalf("insert with --no-triggers failed: %v", err)
	}
	if rows != 2 {
		t.Fatalf("inserted rows = %d, want 2", rows)
	}

	var n int
	d.Pool.QueryRow(ctx, `SELECT count(*) FROM public.smig_guard`).Scan(&n)
	if n != 2 {
		t.Errorf("row count = %d, want 2", n)
	}
}

func TestPlanDropRemovesObjects(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	stmts := []string{
		`CREATE TABLE public.smig_drop (id int)`,
		`CREATE FUNCTION public.smig_drop_fn() RETURNS int LANGUAGE sql AS $$ SELECT 1 $$`,
		`CREATE VIEW public.smig_drop_v AS SELECT 1 AS one`,
	}
	for _, s := range stmts {
		if _, err := d.Pool.Exec(ctx, s); err != nil {
			t.Fatal(err)
		}
	}

	objects := map[string]string{
		"table public.smig_drop":       "",
		"function public.smig_drop_fn()": "",
		"view public.smig_drop_v":       "",
	}
	plan := data.PlanDrop(objects, []string{"public"})
	if len(plan.Schemas) != 0 {
		t.Fatalf("Schemas = %v, want none for public only", plan.Schemas)
	}
	for _, o := range plan.Objects {
		if _, err := d.Pool.Exec(ctx, o.SQL); err != nil {
			t.Fatalf("exec %q: %v", o.SQL, err)
		}
	}

	for _, q := range []struct {
		label string
		sql   string
	}{
		{"table", `SELECT to_regclass('public.smig_drop') IS NULL`},
		{"view", `SELECT to_regclass('public.smig_drop_v') IS NULL`},
		{"function", `SELECT NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'smig_drop_fn')`},
	} {
		var gone bool
		if err := d.Pool.QueryRow(ctx, q.sql).Scan(&gone); err != nil {
			t.Fatal(err)
		}
		if !gone {
			t.Errorf("%s still present after drop", q.label)
		}
	}
}

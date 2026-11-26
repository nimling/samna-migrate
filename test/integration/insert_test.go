//go:build integration

package integration

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/data"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/testdb"
)

var modesTable = data.Table{Schema: "public", Name: "smig_modes"}

func modesFixture(t *testing.T) *db.DB {
	t.Helper()
	d := testdb.Open(t)
	ctx := context.Background()
	for _, q := range []string{
		`CREATE TABLE public.smig_modes (
			id int PRIMARY KEY,
			name text,
			note text,
			sa_owner_id int NOT NULL DEFAULT 0,
			sa_updated_at timestamptz,
			twice int GENERATED ALWAYS AS (id * 2) STORED
		)`,
		`INSERT INTO public.smig_modes (id, name, note, sa_owner_id, sa_updated_at) VALUES
			(1, 'one', 'n1', 11, '2026-01-01T00:00:00Z'),
			(2, 'two', 'n2', 22, '2026-01-01T00:00:00Z'),
			(3, 'three', 'n3', 33, '2026-01-01T00:00:00Z')`,
	} {
		if _, err := d.Pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	return d
}

func dataFile(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func snapshot(t *testing.T, d *db.DB, table string) string {
	t.Helper()
	var out string
	if err := d.Pool.QueryRow(context.Background(),
		`SELECT COALESCE(string_agg(x::text, '|' ORDER BY x::text), '') FROM `+table+` x`).Scan(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

func row(t *testing.T, d *db.DB, id int) (string, string, int) {
	t.Helper()
	var name, note *string
	var owner int
	if err := d.Pool.QueryRow(context.Background(),
		`SELECT name, note, sa_owner_id FROM public.smig_modes WHERE id = $1`, id).Scan(&name, &note, &owner); err != nil {
		t.Fatalf("row %d: %v", id, err)
	}
	s := func(p *string) string {
		if p == nil {
			return "<null>"
		}
		return *p
	}
	return s(name), s(note), owner
}

func counts(r data.Result) [5]int64 {
	return [5]int64{r.Inserted, r.Updated, r.Skipped, r.Deleted, r.Refused}
}

func TestInsertJSONLIntoEmptyTable(t *testing.T) {
	d := modesFixture(t)
	ctx := context.Background()
	if _, err := d.Pool.Exec(ctx, `DELETE FROM public.smig_modes`); err != nil {
		t.Fatal(err)
	}
	path := dataFile(t, "public.smig_modes.jsonl",
		`{"id":1,"name":"one","note":"n1","sa_owner_id":11,"sa_updated_at":null,"twice":999}`+"\n"+
			`{"id":2,"name":"two","note":null,"sa_owner_id":22,"sa_updated_at":"2026-02-02T00:00:00Z"}`+"\n")
	var calls int
	r, err := data.InsertFile(ctx, d, modesTable, path, data.Options{Progress: func(rows, bytes int64) { calls++ }})
	if err != nil {
		t.Fatal(err)
	}
	if r.Rows != 2 || counts(r) != [5]int64{2, 0, 0, 0, 0} {
		t.Fatalf("insert into empty = %+v", r)
	}
	if calls == 0 {
		t.Error("progress was never reported")
	}
	var twice int
	d.Pool.QueryRow(ctx, `SELECT twice FROM public.smig_modes WHERE id = 1`).Scan(&twice)
	if twice != 2 {
		t.Errorf("generated column = %d, want 2 from the table, not the file", twice)
	}
}

func TestInsertDefaultRefusesExistingRow(t *testing.T) {
	d := modesFixture(t)
	before := snapshot(t, d, "public.smig_modes")
	path := dataFile(t, "public.smig_modes.json", `[
  {"id": 9, "name": "nine"},
  {"id": 2, "name": "two again"}
]`)
	_, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{})
	message, hint, ok := data.GetRefusal(err)
	if !ok {
		t.Fatalf("insert over an existing key err = %v, want a refusal", err)
	}
	if !strings.Contains(message, "line 3") || !strings.Contains(message, "id=2") || hint == "" {
		t.Errorf("refusal = %q / %q, want line 3, id=2 and a hint", message, hint)
	}
	if after := snapshot(t, d, "public.smig_modes"); after != before {
		t.Errorf("a refused file wrote rows:\n%s\n%s", before, after)
	}
}

func TestInsertUpsertOverExistingRows(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.jsonl",
		`{"id":1,"name":"uno","note":"n1","sa_owner_id":11,"sa_updated_at":"2026-01-01T00:00:00Z"}`+"\n"+
			`{"id":2,"name":"two","note":"n2","sa_owner_id":22,"sa_updated_at":"2026-01-01T00:00:00Z"}`+"\n"+
			`{"id":4,"name":"four","note":"n4","sa_owner_id":44,"sa_updated_at":null}`+"\n")
	r, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeUpsert})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != [5]int64{1, 1, 1, 0, 0} {
		t.Fatalf("upsert counts = %+v, want 1 inserted, 1 updated, 1 skipped", r)
	}
	if name, _, _ := row(t, d, 1); name != "uno" {
		t.Errorf("row 1 name = %q, want uno", name)
	}
	if name, _, owner := row(t, d, 4); name != "four" || owner != 44 {
		t.Errorf("row 4 = %q %d", name, owner)
	}

	r, err = data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeUpsert})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != [5]int64{0, 0, 3, 0, 0} {
		t.Errorf("a second upsert of the same file = %+v, want 3 skipped", r)
	}
}

func TestInsertMergeOfPartialFile(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.jsonl",
		`{"id":1,"name":"uno"}`+"\n"+
			`{"id":2,"note":"note two"}`+"\n"+
			`{"id":3,"name":"three"}`+"\n"+
			`{"id":5,"name":"five"}`+"\n")
	r, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeMerge})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != [5]int64{1, 2, 1, 0, 0} {
		t.Fatalf("merge counts = %+v, want 1 inserted, 2 updated, 1 skipped", r)
	}
	if name, note, owner := row(t, d, 1); name != "uno" || note != "n1" || owner != 11 {
		t.Errorf("row 1 = %q %q %d, want uno n1 11", name, note, owner)
	}
	if name, note, owner := row(t, d, 2); name != "two" || note != "note two" || owner != 22 {
		t.Errorf("row 2 = %q %q %d, want two, note two, 22", name, note, owner)
	}
	if name, _, owner := row(t, d, 5); name != "five" || owner != 0 {
		t.Errorf("row 5 = %q %d, want five with the default owner", name, owner)
	}
}

func TestInsertUpsertWritesEveryCarriedColumn(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.jsonl", `{"id":1,"name":"uno"}`+"\n"+`{"id":2,"note":"note two"}`+"\n")
	if _, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeUpsert}); err != nil {
		t.Fatal(err)
	}
	if name, note, owner := row(t, d, 1); name != "uno" || note != "<null>" || owner != 11 {
		t.Errorf("row 1 = %q %q %d, want uno, null note, owner untouched", name, note, owner)
	}
	if name, note, _ := row(t, d, 2); name != "<null>" || note != "note two" {
		t.Errorf("row 2 = %q %q, want null name, note two", name, note)
	}
}

func TestInsertSkipLeavesExistingRows(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.json", `[{"id":1,"name":"changed"},{"id":6,"name":"six"}]`)
	r, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeSkip})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != [5]int64{1, 0, 1, 0, 0} {
		t.Fatalf("skip counts = %+v", r)
	}
	if name, _, _ := row(t, d, 1); name != "one" {
		t.Errorf("row 1 name = %q, want one", name)
	}
}

func TestInsertCreate(t *testing.T) {
	d := modesFixture(t)
	same := dataFile(t, "public.smig_modes.jsonl", `{"id":1,"name":"one","note":"n1"}`+"\n"+`{"id":7,"name":"seven"}`+"\n")
	r, err := data.InsertFile(context.Background(), d, modesTable, same, data.Options{Mode: data.ModeCreate})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != [5]int64{1, 0, 1, 0, 0} {
		t.Fatalf("create counts = %+v", r)
	}
	differ := dataFile(t, "public.smig_modes.jsonl", `{"id":8,"name":"eight"}`+"\n"+`{"id":2,"name":"other"}`+"\n")
	_, err = data.InsertFile(context.Background(), d, modesTable, differ, data.Options{Mode: data.ModeCreate})
	if message, _, ok := data.GetRefusal(err); !ok || !strings.Contains(message, "line 2") || !strings.Contains(message, "differs") {
		t.Fatalf("create over a differing row err = %v", err)
	}
	var n int
	d.Pool.QueryRow(context.Background(), `SELECT count(*) FROM public.smig_modes WHERE id = 8`).Scan(&n)
	if n != 0 {
		t.Error("a refused create wrote row 8")
	}
}

func TestInsertLatest(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.jsonl",
		`{"id":1,"name":"older","sa_updated_at":"2025-01-01T00:00:00Z"}`+"\n"+
			`{"id":2,"name":"newer","sa_updated_at":"2026-06-01T00:00:00Z"}`+"\n"+
			`{"id":3,"name":"untimed"}`+"\n")
	r, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeLatest})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != [5]int64{0, 1, 2, 0, 0} {
		t.Fatalf("latest counts = %+v", r)
	}
	if name, _, _ := row(t, d, 1); name != "one" {
		t.Errorf("row 1 = %q, an older row must not win", name)
	}
	if name, _, _ := row(t, d, 2); name != "newer" {
		t.Errorf("row 2 = %q, the newer row must win", name)
	}
}

func TestInsertReplaceDeletesWhatTheFileLacks(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.jsonl", `{"id":1,"name":"one","note":"n1","sa_owner_id":11,"sa_updated_at":"2026-01-01T00:00:00Z"}`+"\n")
	plan, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeReplace, Plan: true})
	if err != nil {
		t.Fatal(err)
	}
	if counts(plan) != [5]int64{0, 0, 1, 2, 0} {
		t.Fatalf("replace plan = %+v, want 1 skipped and 2 deleted", plan)
	}
	r, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeReplace})
	if err != nil {
		t.Fatal(err)
	}
	if counts(r) != counts(plan) {
		t.Errorf("replace run %+v differs from its plan %+v", r, plan)
	}
	var n int
	d.Pool.QueryRow(context.Background(), `SELECT count(*) FROM public.smig_modes`).Scan(&n)
	if n != 1 {
		t.Errorf("rows after replace = %d, want 1", n)
	}
}

func TestInsertPlanCountsAndWritesNothing(t *testing.T) {
	d := modesFixture(t)
	before := snapshot(t, d, "public.smig_modes")
	path := dataFile(t, "public.smig_modes.jsonl",
		`{"id":1,"name":"uno"}`+"\n"+`{"id":2,"name":"two"}`+"\n"+`{"id":10,"name":"ten"}`+"\n"+`{"id":11,"name":"eleven"}`+"\n")
	cases := map[string][5]int64{
		data.ModeInsert: {2, 0, 0, 0, 2},
		data.ModeCreate: {2, 0, 1, 0, 1},
		data.ModeUpsert: {2, 1, 1, 0, 0},
		data.ModeMerge:  {2, 1, 1, 0, 0},
		data.ModeSkip:   {2, 0, 2, 0, 0},
	}
	for mode, want := range cases {
		r, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: mode, Plan: true})
		if err != nil {
			t.Fatalf("plan %s: %v", mode, err)
		}
		if !r.Plan || r.Rows != 4 || counts(r) != want {
			t.Errorf("plan %s = %+v, want %v", mode, counts(r), want)
		}
	}
	if after := snapshot(t, d, "public.smig_modes"); after != before {
		t.Errorf("plan wrote rows:\n%s\n%s", before, after)
	}
}

func TestInsertRefusesUpdateModesWithoutPrimaryKey(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if _, err := d.Pool.Exec(ctx, `CREATE TABLE public.smig_nokey (id int, label text)`); err != nil {
		t.Fatal(err)
	}
	tbl := data.Table{Schema: "public", Name: "smig_nokey"}
	path := dataFile(t, "public.smig_nokey.jsonl", `{"id":1,"label":"a"}`+"\n")
	for _, mode := range []string{data.ModeUpsert, data.ModeMerge, data.ModeSkip, data.ModeCreate, data.ModeLatest, data.ModeReplace} {
		_, err := data.InsertFile(ctx, d, tbl, path, data.Options{Mode: mode})
		if err == nil || !strings.Contains(err.Error(), "no primary key") {
			t.Errorf("mode %s on a table with no primary key err = %v", mode, err)
		}
	}
	r, err := data.InsertFile(ctx, d, tbl, path, data.Options{})
	if err != nil || r.Inserted != 1 {
		t.Fatalf("mode insert on a table with no primary key = %+v %v", r, err)
	}
}

func TestInsertNamesTheLineOfABadRow(t *testing.T) {
	d := modesFixture(t)
	path := dataFile(t, "public.smig_modes.jsonl", `{"id":20}`+"\n"+`{"id":21}`+"\n"+`{"id":"abc"}`+"\n")
	_, err := data.InsertFile(context.Background(), d, modesTable, path, data.Options{Mode: data.ModeUpsert})
	if err == nil || !strings.Contains(err.Error(), "public.smig_modes.jsonl line 3") {
		t.Fatalf("bad row err = %v, want the file and line 3", err)
	}
	dup := dataFile(t, "public.smig_modes.jsonl", `{"id":20}`+"\n"+`{"id":21}`+"\n"+`{"id":20}`+"\n")
	_, err = data.InsertFile(context.Background(), d, modesTable, dup, data.Options{Mode: data.ModeUpsert})
	if err == nil || !strings.Contains(err.Error(), "lines 1 and 3") || !strings.Contains(err.Error(), "id=20") {
		t.Fatalf("duplicate key err = %v, want lines 1 and 3 and id=20", err)
	}
}

func TestDumpFormatsRoundtrip(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	for _, q := range []string{
		`CREATE TABLE public.smig_formats (
			id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
			n int,
			label text,
			meta jsonb,
			doc json,
			tags text[],
			amount numeric,
			at timestamptz,
			raw bytea
		)`,
		`INSERT INTO public.smig_formats (n, label, meta, doc, tags, amount, at, raw) VALUES
			(1, 'it''s "quoted", with a comma', '{"k":1}', '{"a": [1, 2]}', '{a,"b c"}', 1.25, '2026-01-02T03:04:05Z', '\x0102'),
			(2, E'two\nlines', '{"k":[1,2]}', NULL, '{}', 9.990, NULL, NULL),
			(3, '', NULL, '{}', NULL, NULL, '2026-06-07T08:09:10.123456Z', '\x')`,
	} {
		if _, err := d.Pool.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	tbl := data.Table{Schema: "public", Name: "smig_formats"}
	before := snapshot(t, d, "public.smig_formats")
	for _, format := range []string{data.FormatJSON, data.FormatJSONL, data.FormatCSV, data.FormatSQL} {
		dir := t.TempDir()
		count, path, err := data.DumpTable(ctx, d, tbl, dir, data.Options{Format: format})
		if err != nil {
			t.Fatalf("dump %s: %v", format, err)
		}
		if count != 3 || filepath.Base(path) != "public.smig_formats."+format {
			t.Fatalf("dump %s = %d rows to %s", format, count, path)
		}
		if _, err := d.Pool.Exec(ctx, `DELETE FROM public.smig_formats`); err != nil {
			t.Fatal(err)
		}
		r, err := data.InsertFile(ctx, d, tbl, path, data.Options{})
		if err != nil {
			t.Fatalf("insert %s: %v", format, err)
		}
		if format != data.FormatSQL && r.Inserted != 3 {
			t.Errorf("insert %s = %+v, want 3 inserted", format, r)
		}
		if after := snapshot(t, d, "public.smig_formats"); after != before {
			t.Errorf("%s roundtrip changed rows:\n%s\n%s", format, before, after)
		}
	}
}

func TestDumpSQLUpsertAppliesAndRepeats(t *testing.T) {
	d := modesFixture(t)
	ctx := context.Background()
	before := snapshot(t, d, "public.smig_modes")
	_, path, err := data.DumpTable(ctx, d, modesTable, t.TempDir(), data.Options{Format: data.FormatSQL, Mode: data.ModeUpsert})
	if err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(path)
	if !strings.Contains(string(body), `ON CONFLICT ("id") DO UPDATE SET`) {
		t.Fatalf("upsert sql lacks ON CONFLICT DO UPDATE:\n%s", body)
	}
	if _, err := d.Pool.Exec(ctx, `UPDATE public.smig_modes SET name = 'drifted' WHERE id = 2`); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `DELETE FROM public.smig_modes WHERE id = 3`); err != nil {
		t.Fatal(err)
	}

	plan, err := data.InsertFile(ctx, d, modesTable, path, data.Options{Plan: true})
	if err != nil {
		t.Fatal(err)
	}
	if plan.Statements != 1 || len(plan.Tables) != 1 || plan.Tables[0] != "public.smig_modes" {
		t.Errorf("sql plan = %+v, want 1 statement on public.smig_modes", plan)
	}
	r, err := data.InsertFile(ctx, d, modesTable, path, data.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if r.Rows != 2 {
		t.Errorf("sql upsert wrote %d rows, want 2: the drifted one and the missing one", r.Rows)
	}
	if after := snapshot(t, d, "public.smig_modes"); after != before {
		t.Errorf("sql upsert did not restore rows:\n%s\n%s", before, after)
	}
	r, err = data.InsertFile(ctx, d, modesTable, path, data.Options{})
	if err != nil || r.Rows != 0 {
		t.Errorf("a second sql upsert = %+v %v, want 0 rows written", r, err)
	}

	_, replace, err := data.DumpTable(ctx, d, modesTable, t.TempDir(), data.Options{Format: data.FormatSQL, Mode: data.ModeReplace})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Pool.Exec(ctx, `INSERT INTO public.smig_modes (id, name) VALUES (99, 'extra')`); err != nil {
		t.Fatal(err)
	}
	if _, err := data.InsertFile(ctx, d, modesTable, replace, data.Options{}); err != nil {
		t.Fatal(err)
	}
	if after := snapshot(t, d, "public.smig_modes"); after != before {
		t.Errorf("sql replace did not remove the extra row:\n%s\n%s", before, after)
	}

	if _, _, err := data.DumpTable(ctx, d, modesTable, t.TempDir(), data.Options{Format: data.FormatSQL, Mode: data.ModeCreate}); err == nil {
		t.Error("a sql dump with mode create was written")
	}
}

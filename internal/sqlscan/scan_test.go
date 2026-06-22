package sqlscan

import "testing"

func find(objs []Object, kind, name string) *Object {
	for i := range objs {
		if objs[i].Kind == kind && objs[i].Name == name {
			return &objs[i]
		}
	}
	return nil
}

func stat(o *Object, key string) string {
	for _, s := range o.Stats {
		if s.Key == key {
			return s.Val
		}
	}
	return ""
}

func TestScanFunctionIgnoresBodyCreates(t *testing.T) {
	sql := `
CREATE OR REPLACE FUNCTION claimius.attach(p_a UUID, p_b TEXT, OUT p_c JSONB)
    RETURNS JSONB AS $$
BEGIN
    EXECUTE format('CREATE TRIGGER tg_x AFTER INSERT ON %I.%I', a, b);
    CREATE TABLE not_real (id UUID);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
`
	objs := Scan(sql)
	if len(objs) != 1 {
		t.Fatalf("want 1 object, got %d: %+v", len(objs), objs)
	}
	o := find(objs, "function", "claimius.attach")
	if o == nil {
		t.Fatalf("function not found: %+v", objs)
	}
	if got := stat(o, "params"); got != "3" {
		t.Errorf("params = %q, want 3", got)
	}
	if got := stat(o, "out"); got != "1" {
		t.Errorf("out = %q, want 1", got)
	}
	if got := stat(o, "returns"); got != "JSONB" {
		t.Errorf("returns = %q, want JSONB", got)
	}
	if got := stat(o, "lang"); got != "plpgsql" {
		t.Errorf("lang = %q, want plpgsql", got)
	}
	if got := stat(o, "vol"); got != "stable" {
		t.Errorf("vol = %q, want stable", got)
	}
	if got := stat(o, "sec"); got != "definer" {
		t.Errorf("sec = %q, want definer", got)
	}
}

func TestScanFunctionNoParams(t *testing.T) {
	sql := `CREATE FUNCTION get_app_id() RETURNS SETOF claimius.samna_app AS $$ SELECT 1 $$ LANGUAGE sql;`
	o := find(Scan(sql), "function", "get_app_id")
	if o == nil {
		t.Fatal("not found")
	}
	if got := stat(o, "params"); got != "0" {
		t.Errorf("params = %q, want 0", got)
	}
	if got := stat(o, "returns"); got != "SETOF" {
		t.Errorf("returns = %q, want SETOF", got)
	}
}

func TestScanTable(t *testing.T) {
	sql := `
CREATE TABLE public.bookable (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    owner_id UUID REFERENCES claimius.organization (id),
    price NUMERIC(10,2),
    CONSTRAINT fk_loc FOREIGN KEY (location_id) REFERENCES claimius.location (id),
    CHECK (price >= 0)
);
`
	o := find(Scan(sql), "table", "public.bookable")
	if o == nil {
		t.Fatal("table not found")
	}
	if got := stat(o, "cols"); got != "4" {
		t.Errorf("cols = %q, want 4", got)
	}
	if got := stat(o, "pk"); got != "yes" {
		t.Errorf("pk = %q, want yes", got)
	}
	if got := stat(o, "fk"); got != "2" {
		t.Errorf("fk = %q, want 2", got)
	}
	if got := stat(o, "checks"); got != "1" {
		t.Errorf("checks = %q, want 1", got)
	}
}

func TestScanIndexUniquePartial(t *testing.T) {
	sql := `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_x ON activity USING btree (a, b, c) WHERE sa_deleted_at IS NULL;`
	o := find(Scan(sql), "index", "idx_x")
	if o == nil {
		t.Fatal("index not found")
	}
	if got := stat(o, "on"); got != "activity" {
		t.Errorf("on = %q, want activity", got)
	}
	if got := stat(o, "cols"); got != "3" {
		t.Errorf("cols = %q, want 3", got)
	}
	if got := stat(o, "unique"); got != "yes" {
		t.Errorf("unique = %q, want yes", got)
	}
	if got := stat(o, "partial"); got != "yes" {
		t.Errorf("partial = %q, want yes", got)
	}
	if got := stat(o, "method"); got != "btree" {
		t.Errorf("method = %q, want btree", got)
	}
}

func TestScanTrigger(t *testing.T) {
	sql := `CREATE TRIGGER tg_calc AFTER INSERT OR UPDATE ON public.bookable FOR EACH STATEMENT EXECUTE FUNCTION claimius.calc();`
	o := find(Scan(sql), "trigger", "tg_calc")
	if o == nil {
		t.Fatal("trigger not found")
	}
	if got := stat(o, "on"); got != "public.bookable" {
		t.Errorf("on = %q, want public.bookable", got)
	}
	if got := stat(o, "when"); got != "after" {
		t.Errorf("when = %q, want after", got)
	}
	if got := stat(o, "events"); got != "insert,update" {
		t.Errorf("events = %q, want insert,update", got)
	}
	if got := stat(o, "level"); got != "statement" {
		t.Errorf("level = %q, want statement", got)
	}
	if got := stat(o, "fn"); got != "claimius.calc" {
		t.Errorf("fn = %q, want claimius.calc", got)
	}
}

func TestScanAlterAndEnumAndComments(t *testing.T) {
	sql := `
-- add a column
ALTER TABLE bookable_type ADD COLUMN external_id TEXT DEFAULT NULL;
/* an enum */
CREATE TYPE public.status AS ENUM ('a', 'b', 'c');
INSERT INTO seed (id, name) VALUES (1, 'x'), (2, 'y'), (3, 'z');
`
	objs := Scan(sql)
	a := find(objs, "alter", "bookable_type")
	if a == nil {
		t.Fatal("alter not found")
	}
	if got := stat(a, "adds"); got != "1" {
		t.Errorf("adds = %q, want 1", got)
	}
	e := find(objs, "type", "public.status")
	if e == nil {
		t.Fatal("type not found")
	}
	if got := stat(e, "shape"); got != "enum" {
		t.Errorf("shape = %q, want enum", got)
	}
	if got := stat(e, "values"); got != "3" {
		t.Errorf("values = %q, want 3", got)
	}
	ins := find(objs, "insert", "seed")
	if ins == nil {
		t.Fatal("insert not found")
	}
	if got := stat(ins, "rows"); got != "3" {
		t.Errorf("rows = %q, want 3", got)
	}
}

func TestScanLineNumbers(t *testing.T) {
	sql := "CREATE SCHEMA a;\n\nCREATE SCHEMA b;\n"
	objs := Scan(sql)
	if len(objs) != 2 {
		t.Fatalf("want 2, got %d", len(objs))
	}
	if objs[1].Line != 3 {
		t.Errorf("second object line = %d, want 3", objs[1].Line)
	}
}

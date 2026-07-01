package data

import "testing"

func TestPlanDropSplitsPublicAndSchemas(t *testing.T) {
	objects := map[string]string{
		"table public.smig_a":               "",
		"view public.v_a":                   "",
		"sequence public.s_a":               "",
		"function public.fn_a(integer)":     "",
		"type public.t_a":                   "",
		"enum public.e_a":                   "",
		"table claimius.x":                  "",
		"function claimius.get_access(uuid)": "",
		"constraint public.smig_a.pk":       "",
		"index public.idx_a":               "",
		"trigger public.smig_a.tg":         "",
		"grant public.smig_a bookable":     "",
	}
	plan := PlanDrop(objects, []string{"public", "claimius"})

	if len(plan.Schemas) != 1 || plan.Schemas[0] != "claimius" {
		t.Fatalf("Schemas = %v, want [claimius]", plan.Schemas)
	}

	got := map[string]string{}
	for _, o := range plan.Objects {
		got[o.Kind] = o.SQL
	}
	if len(got) != 6 {
		t.Fatalf("public objects = %d, want 6: %#v", len(plan.Objects), plan.Objects)
	}
	want := map[string]string{
		"view":     `DROP VIEW IF EXISTS "public"."v_a" CASCADE;`,
		"table":    `DROP TABLE IF EXISTS "public"."smig_a" CASCADE;`,
		"sequence": `DROP SEQUENCE IF EXISTS "public"."s_a" CASCADE;`,
		"function": `DROP FUNCTION IF EXISTS "public"."fn_a"(integer) CASCADE;`,
		"type":     `DROP TYPE IF EXISTS "public"."t_a" CASCADE;`,
		"enum":     `DROP TYPE IF EXISTS "public"."e_a" CASCADE;`,
	}
	for kind, sql := range want {
		if got[kind] != sql {
			t.Errorf("%s SQL = %q, want %q", kind, got[kind], sql)
		}
	}
}

func TestPlanDropOrdersViewsBeforeTables(t *testing.T) {
	objects := map[string]string{
		"type public.t":     "",
		"function public.f()": "",
		"sequence public.s": "",
		"table public.tab":  "",
		"view public.v":     "",
	}
	plan := PlanDrop(objects, []string{"public"})
	order := []string{}
	for _, o := range plan.Objects {
		order = append(order, o.Kind)
	}
	want := []string{"view", "table", "sequence", "function", "type"}
	if len(order) != len(want) {
		t.Fatalf("order = %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("order = %v, want %v", order, want)
		}
	}
}

func TestPlanDropNoPublic(t *testing.T) {
	objects := map[string]string{"table claimius.x": ""}
	plan := PlanDrop(objects, []string{"claimius"})
	if len(plan.Objects) != 0 {
		t.Errorf("Objects = %v, want none", plan.Objects)
	}
	if len(plan.Schemas) != 1 || plan.Schemas[0] != "claimius" {
		t.Errorf("Schemas = %v, want [claimius]", plan.Schemas)
	}
	if plan.Empty() {
		t.Error("Empty() true with a schema to drop")
	}
}

func TestPlanDropEmpty(t *testing.T) {
	plan := PlanDrop(map[string]string{}, []string{"public"})
	if !plan.Empty() {
		t.Errorf("Empty() false for no objects and public only: %#v", plan)
	}
}

func TestQuoteIdent(t *testing.T) {
	cases := map[string]string{
		"foo":   `"foo"`,
		`a"b`:   `"a""b"`,
		"claim": `"claim"`,
	}
	for in, want := range cases {
		if got := QuoteIdent(in); got != want {
			t.Errorf("QuoteIdent(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseTable(t *testing.T) {
	cases := []struct {
		in     string
		schema string
		name   string
		ok     bool
	}{
		{"public.foo", "public", "foo", true},
		{"claimius.samna_user", "claimius", "samna_user", true},
		{"foo", "", "", false},
		{"a.", "", "", false},
		{".b", "", "", false},
	}
	for _, c := range cases {
		tbl, ok := ParseTable(c.in)
		if ok != c.ok || tbl.Schema != c.schema || tbl.Name != c.name {
			t.Errorf("ParseTable(%q) = %+v %v, want {%s %s} %v", c.in, tbl, ok, c.schema, c.name, c.ok)
		}
	}
}

func TestTableFormatting(t *testing.T) {
	tbl := Table{Schema: "public", Name: "bookable"}
	if tbl.Qualified() != "public.bookable" {
		t.Errorf("Qualified = %q", tbl.Qualified())
	}
	if tbl.Quoted() != `"public"."bookable"` {
		t.Errorf("Quoted = %q", tbl.Quoted())
	}
	if tbl.FileName() != "public.bookable.json" {
		t.Errorf("FileName = %q", tbl.FileName())
	}
}

package reconcile

import "testing"

func TestParseIdentity(t *testing.T) {
	cases := []struct {
		id    string
		kind  string
		name  string
		table string
		ok    bool
	}{
		{"function public.foo(integer)", "function", "public.foo", "", true},
		{"table public.bookable", "table", "public.bookable", "", true},
		{"constraint public.t.t_pkey", "constraint", "t_pkey", "public.t", true},
		{"trigger public.t.tg_x", "trigger", "tg_x", "public.t", true},
		{"index public.idx_x", "index", "public.idx_x", "", true},
		{"enum public.color", "type", "public.color", "", true},
		{"type claimius.access", "type", "claimius.access", "", true},
		{"view public.v", "view", "public.v", "", true},
		{"sequence public.s", "sequence", "public.s", "", true},
		{"grant public.t alice", "grant", "", "", true},
		{"comment table public.t", "comment", "", "", true},
		{"nonsense", "", "", "", false},
		{"weird thing", "", "", "", false},
	}
	for _, c := range cases {
		kind, name, table, _, ok := parseIdentity(c.id)
		if ok != c.ok {
			t.Fatalf("%q: ok=%v want %v", c.id, ok, c.ok)
		}
		if !ok {
			continue
		}
		if kind != c.kind {
			t.Fatalf("%q: kind=%q want %q", c.id, kind, c.kind)
		}
		if c.name != "" && name != c.name {
			t.Fatalf("%q: name=%q want %q", c.id, name, c.name)
		}
		if table != c.table {
			t.Fatalf("%q: table=%q want %q", c.id, table, c.table)
		}
	}
}

func TestPhaseOrdering(t *testing.T) {
	if !(phaseOf("type") < phaseOf("table") && phaseOf("table") < phaseOf("function") &&
		phaseOf("function") < phaseOf("index") && phaseOf("index") < phaseOf("trigger")) {
		t.Fatalf("phase order wrong: type %d table %d function %d index %d trigger %d",
			phaseOf("type"), phaseOf("table"), phaseOf("function"), phaseOf("index"), phaseOf("trigger"))
	}
}

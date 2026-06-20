package dump

import (
	"strings"
	"testing"
)

func TestSplitIdent(t *testing.T) {
	s, n := splitIdent("claimius.get_access")
	if s != "claimius" || n != "get_access" {
		t.Errorf("splitIdent qualified: %q %q", s, n)
	}
	s, n = splitIdent("tg_calc_access")
	if s != "" || n != "tg_calc_access" {
		t.Errorf("splitIdent bare: %q %q", s, n)
	}
}

func TestInjectIndexGuard(t *testing.T) {
	got := injectIndexGuard("CREATE INDEX foo_idx ON public.a USING btree (id);")
	if !strings.HasPrefix(got, "CREATE INDEX IF NOT EXISTS foo_idx") {
		t.Errorf("plain index: %q", got)
	}
	got = injectIndexGuard("CREATE UNIQUE INDEX bar_idx ON public.b USING btree (id);")
	if !strings.HasPrefix(got, "CREATE UNIQUE INDEX IF NOT EXISTS bar_idx") {
		t.Errorf("unique index: %q", got)
	}
	already := "CREATE INDEX IF NOT EXISTS baz_idx ON public.c USING btree (id);"
	if injectIndexGuard(already) != already {
		t.Errorf("guarded index must pass through")
	}
}

func TestGuardType(t *testing.T) {
	got := guardType("status", "CREATE TYPE public.status AS ENUM ('a', 'b');")
	if !strings.Contains(got, "IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'status')") {
		t.Errorf("missing pg_type guard: %q", got)
	}
	if !strings.Contains(got, "CREATE TYPE public.status AS ENUM ('a', 'b');") {
		t.Errorf("missing create inside guard: %q", got)
	}
	if strings.Count(got, ";") < 2 {
		t.Errorf("guard block not terminated: %q", got)
	}
}

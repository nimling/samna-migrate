package lint

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/steps"
)

func writeStep(t *testing.T, dbDir, folder, name, content string) {
	t.Helper()
	dir := filepath.Join(dbDir, folder)
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644)
}

func twoStepConfig() *steps.Config {
	return &steps.Config{Steps: []steps.Step{
		{Name: "Base", Type: "base", Slug: "base", Include: []steps.IncludeEntry{{Path: "base/"}}},
		{Name: "Migrations", Type: "migration", Include: []steps.IncludeEntry{{Path: "migrations/"}}},
	}}
}

func findingFor(r *Result, file string) []Finding {
	out := []Finding{}
	for _, f := range r.Findings {
		if f.File == file {
			out = append(out, f)
		}
	}
	return out
}

func TestLintCommentOnFunctionWithoutSignature(t *testing.T) {
	dbDir := t.TempDir()
	writeStep(t, dbDir, "migrations", "V1.0__base_bad_comment.sql",
		"CREATE OR REPLACE FUNCTION public.f() RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;\nCOMMENT ON FUNCTION public.f IS 'x';")
	writeStep(t, dbDir, "migrations", "V1.1__base_good_comment.sql",
		"CREATE OR REPLACE FUNCTION public.g(a INT) RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;\nCOMMENT ON FUNCTION public.g(INT) IS 'x';")
	r, err := Run(twoStepConfig(), dbDir)
	if err != nil {
		t.Fatal(err)
	}
	bad := findingFor(r, "migrations/V1.0__base_bad_comment.sql")
	if len(bad) == 0 || bad[0].Level != "error" {
		t.Errorf("unsigned COMMENT ON FUNCTION must be an error: %+v", r.Findings)
	}
	if len(findingFor(r, "migrations/V1.1__base_good_comment.sql")) != 0 {
		t.Errorf("signed COMMENT ON FUNCTION must pass: %+v", r.Findings)
	}
}

func TestLintIdempotencyWarnings(t *testing.T) {
	dbDir := t.TempDir()
	writeStep(t, dbDir, "migrations", "V1.0__base_index.sql", "CREATE INDEX foo_idx ON public.a(id);")
	writeStep(t, dbDir, "migrations", "V1.1__base_column.sql", "ALTER TABLE public.a ADD COLUMN n INT;")
	writeStep(t, dbDir, "migrations", "V1.2__base_function.sql", "CREATE FUNCTION public.h() RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;")
	writeStep(t, dbDir, "base", "V1.0__base_guarded.sql", "CREATE INDEX bar_idx ON public.b(id);")
	r, err := Run(twoStepConfig(), dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if r.Warnings != 3 {
		t.Errorf("warnings = %d, want 3: %+v", r.Warnings, r.Findings)
	}
	if len(findingFor(r, "base/V1.0__base_guarded.sql")) != 0 {
		t.Errorf("index idempotency check must not apply to base steps")
	}
}

func TestLintSessionReplicationRoleAndGrammar(t *testing.T) {
	dbDir := t.TempDir()
	writeStep(t, dbDir, "base", "V1.0__base_roles.sql", "SET session_replication_role = replica;")
	writeStep(t, dbDir, "base", "badname.sql", "SELECT 1;")
	r, err := Run(twoStepConfig(), dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if r.Errors != 2 {
		t.Errorf("errors = %d, want 2: %+v", r.Errors, r.Findings)
	}
}

func TestLintCreateTypeGuard(t *testing.T) {
	dbDir := t.TempDir()
	writeStep(t, dbDir, "base", "V1.0__base_bare_type.sql", "CREATE TYPE public.s AS ENUM ('a');")
	writeStep(t, dbDir, "base", "V1.1__base_guarded_type.sql",
		"DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 's2') THEN CREATE TYPE public.s2 AS ENUM ('a'); END IF; END $$;")
	r, err := Run(twoStepConfig(), dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(findingFor(r, "base/V1.0__base_bare_type.sql")) != 1 {
		t.Errorf("bare CREATE TYPE must warn: %+v", r.Findings)
	}
	if len(findingFor(r, "base/V1.1__base_guarded_type.sql")) != 0 {
		t.Errorf("guarded CREATE TYPE must pass: %+v", r.Findings)
	}
}

func TestLintMultiWordSlug(t *testing.T) {
	dbDir := t.TempDir()
	writeStep(t, dbDir, "debug_user", "V1.0__debug_user_seed.sql", "SELECT 1;")
	writeStep(t, dbDir, "debug_user", "V1.1__other_seed.sql", "SELECT 1;")
	cfg := &steps.Config{Steps: []steps.Step{
		{Name: "DebugUser", Type: "seed", Slug: "debug_user", Include: []steps.IncludeEntry{{Path: "debug_user/"}}},
	}}
	r, err := Run(cfg, dbDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(findingFor(r, "debug_user/V1.0__debug_user_seed.sql")) != 0 {
		t.Errorf("debug_user_seed must match the debug_user slug: %+v", r.Findings)
	}
	if len(findingFor(r, "debug_user/V1.1__other_seed.sql")) == 0 {
		t.Errorf("other_seed must be flagged as an undeclared slug: %+v", r.Findings)
	}
}

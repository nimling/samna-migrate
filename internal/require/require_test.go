package require

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/steps"
)

func scanFixture(t *testing.T, files map[string]string) []Requirement {
	t.Helper()
	dir := t.TempDir()
	sqlDir := filepath.Join(dir, "sql")
	if err := os.MkdirAll(sqlDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(sqlDir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := &steps.Config{Steps: []steps.Step{{
		Name:    "base",
		Type:    "base",
		Include: []steps.IncludeEntry{{Path: "sql"}},
	}}}
	reqs, err := Scan(cfg, dir)
	if err != nil {
		t.Fatal(err)
	}
	return reqs
}

func has(reqs []Requirement, kind, name string) bool {
	for _, r := range reqs {
		if r.Kind == kind && r.Name == name {
			return true
		}
	}
	return false
}

func TestScanNetsRolesCreatedInDoBlock(t *testing.T) {
	reqs := scanFixture(t, map[string]string{
		"V1.0__base.sql": `DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'claimius_reader') THEN
        CREATE ROLE claimius_reader;
    END IF;
END $$;`,
		"V2.0__grants.sql": `GRANT EXECUTE ON FUNCTION claimius.get_access(p_user uuid, p_app uuid) TO claimius_reader;
GRANT EXECUTE ON FUNCTION claimius.get_access(p_user uuid, p_app uuid) TO PUBLIC;
GRANT SELECT ON claimius.audit TO external_reporter;`,
	})
	if has(reqs, "role", "claimius_reader") {
		t.Errorf("role created in a DO block must net out: %+v", reqs)
	}
	if has(reqs, "role", "public") {
		t.Errorf("PUBLIC is a builtin pseudo role: %+v", reqs)
	}
	if !has(reqs, "role", "external_reporter") {
		t.Errorf("granted role with no creator must be required: %+v", reqs)
	}
}

func TestScanIgnoresProseInFunctionBodies(t *testing.T) {
	reqs := scanFixture(t, map[string]string{
		"V1.0__fn.sql": `CREATE FUNCTION note() RETURNS void AS $$
BEGIN
    RAISE NOTICE 'remember to grant the deploy role to the operator before running this in production';
END
$$ LANGUAGE plpgsql;`,
	})
	for _, r := range reqs {
		if r.Kind == "role" {
			t.Errorf("prose inside a function body must not yield a role requirement: %+v", reqs)
		}
	}
}

func TestScanDetectsExtensions(t *testing.T) {
	reqs := scanFixture(t, map[string]string{
		"V1.0__ext.sql": `CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION "uuid-ossp";`,
	})
	if !has(reqs, "extension", "pgcrypto") {
		t.Errorf("pgcrypto must be required: %+v", reqs)
	}
	if !has(reqs, "extension", "uuid-ossp") {
		t.Errorf("quoted extension name must be required: %+v", reqs)
	}
}

func TestScanExcludesBuiltinLanguagesAndNetsProvided(t *testing.T) {
	reqs := scanFixture(t, map[string]string{
		"V1.0__fns.sql": `CREATE FUNCTION a() RETURNS void AS $$ BEGIN END $$ LANGUAGE plpgsql;
CREATE FUNCTION b() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;
CREATE TRUSTED LANGUAGE plperl;
CREATE FUNCTION c() RETURNS void AS $$ $$ LANGUAGE plperl;
CREATE FUNCTION d() RETURNS void AS $$ $$ LANGUAGE plpython3u;`,
	})
	if has(reqs, "language", "plpgsql") || has(reqs, "language", "sql") {
		t.Errorf("builtin languages must be excluded: %+v", reqs)
	}
	if has(reqs, "language", "plperl") {
		t.Errorf("language created in the same set must net out: %+v", reqs)
	}
	if !has(reqs, "language", "plpython3u") {
		t.Errorf("non builtin language with no creator must be required: %+v", reqs)
	}
}

func TestScanNetsExtensionProvidedLanguage(t *testing.T) {
	reqs := scanFixture(t, map[string]string{
		"V1.0__plpy.sql": `CREATE EXTENSION IF NOT EXISTS plpython3u;
CREATE FUNCTION d() RETURNS void AS $$ $$ LANGUAGE plpython3u;`,
	})
	if has(reqs, "language", "plpython3u") {
		t.Errorf("language provided by a required extension must net out: %+v", reqs)
	}
	if !has(reqs, "extension", "plpython3u") {
		t.Errorf("the extension itself stays a requirement: %+v", reqs)
	}
}

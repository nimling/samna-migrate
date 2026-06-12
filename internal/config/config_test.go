package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFromEnvDefaults(t *testing.T) {
	keys := []string{"PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE", "PGSSLMODE", "MIGRATE_SCHEMA", "DB_DIR"}
	for _, k := range keys {
		t.Setenv(k, "")
	}
	cfg := FromEnv()
	if cfg.PGPort != "5432" {
		t.Errorf("PGPort default: got %q want 5432", cfg.PGPort)
	}
	if cfg.PGUser != "postgres" {
		t.Errorf("PGUser default: got %q want postgres", cfg.PGUser)
	}
	if cfg.PGSSLMode != "disable" {
		t.Errorf("PGSSLMode default: got %q want disable", cfg.PGSSLMode)
	}
	if cfg.StepsFile != "./database/migrate.yml" {
		t.Errorf("StepsFile default: got %q", cfg.StepsFile)
	}
}

func TestFromEnvOverride(t *testing.T) {
	t.Setenv("PGHOST", "db.example.com")
	t.Setenv("PGPORT", "5433")
	t.Setenv("PGUSER", "alice")
	t.Setenv("PGDATABASE", "bookable")
	t.Setenv("PGSSLMODE", "require")
	t.Setenv("MIGRATE_SCHEMA", "/tmp/migrate.yml")
	t.Setenv("DB_DIR", "/tmp/db")

	cfg := FromEnv()
	if cfg.PGHost != "db.example.com" {
		t.Errorf("PGHost: got %q", cfg.PGHost)
	}
	if cfg.PGPort != "5433" {
		t.Errorf("PGPort: got %q", cfg.PGPort)
	}
	if cfg.PGUser != "alice" {
		t.Errorf("PGUser: got %q", cfg.PGUser)
	}
	if cfg.PGDatabase != "bookable" {
		t.Errorf("PGDatabase: got %q", cfg.PGDatabase)
	}
	if cfg.PGSSLMode != "require" {
		t.Errorf("PGSSLMode: got %q", cfg.PGSSLMode)
	}
	if cfg.StepsFile != "/tmp/migrate.yml" {
		t.Errorf("StepsFile: got %q", cfg.StepsFile)
	}
	if cfg.DBDir != "/tmp/db" {
		t.Errorf("DBDir: got %q", cfg.DBDir)
	}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name    string
		c       Config
		wantErr bool
	}{
		{"ok", Config{PGUser: "u", PGDatabase: "d"}, false},
		{"missing user", Config{PGDatabase: "d"}, true},
		{"missing db", Config{PGUser: "u"}, true},
		{"both missing", Config{}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.c.Validate()
			if (err != nil) != tc.wantErr {
				t.Errorf("err = %v, wantErr %v", err, tc.wantErr)
			}
		})
	}
}

func TestIsCI(t *testing.T) {
	t.Setenv("CI", "")
	t.Setenv("GITHUB_ACTIONS", "")
	c := &Config{}
	if c.IsCI() {
		t.Error("expected not CI without env vars")
	}
	t.Setenv("CI", "true")
	if !c.IsCI() {
		t.Error("expected CI when CI=true")
	}
	t.Setenv("CI", "")
	t.Setenv("GITHUB_ACTIONS", "true")
	if !c.IsCI() {
		t.Error("expected CI when GITHUB_ACTIONS=true")
	}
}

func TestConnString(t *testing.T) {
	c := &Config{
		PGHost: "h", PGPort: "5432", PGUser: "u", PGPassword: "p",
		PGDatabase: "d", PGSSLMode: "disable",
	}
	got := c.ConnString()
	want := "host=h port=5432 user=u password=p dbname=d sslmode=disable"
	if got != want {
		t.Errorf("conn string mismatch:\n got  %q\n want %q", got, want)
	}
}

func TestLoadDotEnv(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	contents := `# comment
PGHOST=example
PGUSER="quoted"
PGPORT='5435'

EMPTY=
`
	if err := os.WriteFile(p, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGHOST", "")
	t.Setenv("PGUSER", "")
	t.Setenv("PGPORT", "")
	t.Setenv("EMPTY", "")
	if err := LoadDotEnv(p); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("PGHOST") != "example" {
		t.Errorf("PGHOST: got %q", os.Getenv("PGHOST"))
	}
	if os.Getenv("PGUSER") != "quoted" {
		t.Errorf("PGUSER quoted: got %q", os.Getenv("PGUSER"))
	}
	if os.Getenv("PGPORT") != "5435" {
		t.Errorf("PGPORT single-quoted: got %q", os.Getenv("PGPORT"))
	}
}

func TestLoadDotEnvNoOverride(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	if err := os.WriteFile(p, []byte("PGHOST=from_dotenv\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGHOST", "from_env")
	if err := LoadDotEnv(p); err != nil {
		t.Fatal(err)
	}
	if os.Getenv("PGHOST") != "from_env" {
		t.Errorf("expected dotenv NOT to override existing env, got %q", os.Getenv("PGHOST"))
	}
}

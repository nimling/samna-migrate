package migrate

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/spf13/pflag"
)

func runConfig(t *testing.T, args ...string) []byte {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.PersistentFlags().Lookup("env").Value.(pflag.SliceValue).Replace(nil)
	rootCmd.SetArgs(args)
	defer rootCmd.SetArgs(nil)
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("%v: %v\n%s", args, err, out.String())
	}
	return out.Bytes()
}

func TestEnvFileLoadsEveryKey(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Chdir(dir)
	path := filepath.Join(dir, ".env.tst")
	body := "# comment\nPGHOST=example\nPGUSER=\"quoted\"\nPGPORT='5435'\nPGPASSWORD=hunter22\nSAUTH_DEBUG_USER_ID=abc\n"
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"PGHOST", "PGUSER", "PGPORT", "PGPASSWORD", "SAUTH_DEBUG_USER_ID"} {
		os.Unsetenv(key)
		t.Cleanup(func() { os.Unsetenv(key) })
	}
	out := runConfig(t, "config", "get", "--env="+path)
	for key, want := range map[string]string{"PGHOST": "example", "PGUSER": "quoted", "PGPORT": "5435", "PGPASSWORD": "hunter22", "SAUTH_DEBUG_USER_ID": "abc"} {
		if got := os.Getenv(key); got != want {
			t.Errorf("%s: got %q, want %q", key, got, want)
		}
	}
	var loaded struct {
		Values []struct {
			Key   string `json:"key"`
			Value string `json:"value"`
			Layer string `json:"layer"`
		} `json:"values"`
	}
	if err := json.Unmarshal(out, &loaded); err != nil {
		t.Fatalf("config get json: %v\n%s", err, out)
	}
	for _, value := range loaded.Values {
		if value.Key == "pgpassword" && (value.Value != "xxxxer22" || value.Layer != "env file") {
			t.Errorf("pgpassword: got %q from %q", value.Value, value.Layer)
		}
	}
}

func TestEnvFileYieldsToProcess(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Chdir(dir)
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("PGHOST=from_dotenv\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PGHOST", "from_env")
	runConfig(t, "config", "get", "--env="+path)
	if got := os.Getenv("PGHOST"); got != "from_env" {
		t.Errorf("PGHOST: got %q, want the process value", got)
	}
}

func TestNamedConfigSetsSchema(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	t.Chdir(dir)
	t.Setenv("MIGRATE_SCHEMA", "")
	os.Unsetenv("MIGRATE_SCHEMA")
	runConfig(t, "config", "set", "--to=tst", "migrate_schema=./db/steps.yml", "pghost=tst.example")
	runConfig(t, "config", "get", "--config=tst")
	if stepsFile != "./db/steps.yml" {
		t.Errorf("schema: got %q", stepsFile)
	}
	os.Unsetenv("MIGRATE_SCHEMA")
	os.Unsetenv("PGHOST")
}

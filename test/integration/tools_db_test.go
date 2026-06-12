//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/testdb"
	"github.com/nimling/samna-migrate/internal/tools"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func TestQueryReadonlyAllowsSelect(t *testing.T) {
	d := testdb.Open(t)
	c := tools.New(d, "")
	result, err := c.Dispatch(context.Background(), "query_readonly",
		[]byte(`{"sql":"SELECT 1 AS one"}`))
	if err != nil {
		t.Fatal(err)
	}
	rows, ok := result.([]map[string]any)
	if !ok || len(rows) != 1 {
		t.Fatalf("rows = %#v", result)
	}
}

func TestQueryReadonlyRejectsInsert(t *testing.T) {
	d := testdb.Open(t)
	c := tools.New(d, "")
	result, err := c.Dispatch(context.Background(), "query_readonly",
		[]byte(`{"sql":"INSERT INTO foo VALUES (1)"}`))
	if err != nil {
		t.Fatal(err)
	}
	m, ok := result.(map[string]string)
	if !ok || !strings.Contains(m["error"], "only SELECT") {
		t.Errorf("expected rejection, got %#v", result)
	}
}

func TestValidateSQLOK(t *testing.T) {
	d := testdb.Open(t)
	c := tools.New(d, "")
	result, err := c.Dispatch(context.Background(), "validate_sql",
		[]byte(`{"sql":"SELECT 1"}`))
	if err != nil {
		t.Fatal(err)
	}
	m := result.(map[string]any)
	if m["ok"] != true {
		t.Errorf("validate_sql for SELECT 1 returned %#v", m)
	}
}

func TestValidateSQLFail(t *testing.T) {
	d := testdb.Open(t)
	c := tools.New(d, "")
	result, err := c.Dispatch(context.Background(), "validate_sql",
		[]byte(`{"sql":"SELEC ROM nowhere"}`))
	if err != nil {
		t.Fatal(err)
	}
	m := result.(map[string]any)
	if m["ok"] != false {
		t.Errorf("validate_sql for garbage returned %#v", m)
	}
}

func TestListAppliedMigrations(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	d.Pool.Exec(ctx, `SET samna_migrate.upgrade_mode = 'true'`)
	d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.history (file_path, sha256, success, action_type, attempt, applied_at)
		VALUES ('m/V1.sql', 'sha1', true, 'apply', 1, now())`)
	d.Pool.Exec(ctx, `
		INSERT INTO samna_migrate.file (step_name, step_type, slug, file_name, file_path,
		                                 sha256, size_bytes, state, position,
		                                 applied_at, applied_history_id, applied_sha256, applied_position)
		VALUES ('M', 'migration', 'migration', 'V1.sql', 'm/V1.sql', 'sha1', 0, 'applied', 1,
		        now(), (SELECT id FROM samna_migrate.history WHERE file_path = 'm/V1.sql' LIMIT 1),
		        'sha1', 1)`)

	c := tools.New(d, "")
	result, err := c.Dispatch(ctx, "list_applied_migrations", []byte(`{"limit":10}`))
	if err != nil {
		t.Fatal(err)
	}
	rows, ok := result.([]map[string]any)
	if !ok || len(rows) != 1 {
		t.Fatalf("rows = %#v", result)
	}
	if rows[0]["file_path"] != "m/V1.sql" {
		t.Errorf("file_path = %v", rows[0]["file_path"])
	}
}

func TestGetMigrationFile(t *testing.T) {
	d := testdb.Open(t)
	dir := t.TempDir()
	migDir := dir + "/migrations"
	if err := writeFile(migDir+"/V1.sql", "SELECT 1;"); err != nil {
		t.Fatal(err)
	}
	c := tools.New(d, dir)
	result, err := c.Dispatch(context.Background(), "get_migration_file",
		[]byte(`{"file_path":"migrations/V1.sql"}`))
	if err != nil {
		t.Fatal(err)
	}
	m := result.(map[string]any)
	if !strings.Contains(m["sql"].(string), "SELECT 1") {
		t.Errorf("sql content: %#v", m)
	}
}

func TestGetDBObjects(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	c := tools.New(d, "")
	result, err := c.Dispatch(ctx, "get_db_objects", []byte(`{"schema":"samna_migrate"}`))
	if err != nil {
		t.Fatal(err)
	}
	rows := result.([]map[string]string)
	found := map[string]bool{}
	for _, r := range rows {
		found[r["name"]] = true
	}
	for _, want := range []string{"state", "file", "history", "down_proposal"} {
		if !found[want] {
			t.Errorf("missing object %q in get_db_objects result", want)
		}
	}
	_ = json.RawMessage{} // keep encoding/json import
}

func writeFile(path, content string) error {
	dir := path[:lastSlash(path)]
	if err := osMkdir(dir); err != nil {
		return err
	}
	return osWrite(path, content)
}

func lastSlash(s string) int {
	for i := len(s) - 1; i >= 0; i-- {
		if s[i] == '/' {
			return i
		}
	}
	return 0
}

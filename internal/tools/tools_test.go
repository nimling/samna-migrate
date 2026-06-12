package tools

import (
	"encoding/json"
	"testing"
)

func TestIsSelectOnly(t *testing.T) {
	cases := []struct {
		sql  string
		want bool
	}{
		{"SELECT 1", true},
		{"  select 1", true},
		{"SELECT a FROM t WHERE id = 1", true},
		{"WITH x AS (SELECT 1) SELECT * FROM x", true},
		{"EXPLAIN SELECT 1", true},
		{"INSERT INTO t VALUES (1)", false},
		{"UPDATE t SET a = 1", false},
		{"DELETE FROM t", false},
		{"TRUNCATE TABLE t", false},
		{"DROP TABLE t", false},
		{"ALTER TABLE t ADD COLUMN a INT", false},
		{"CREATE TABLE t (id INT)", false},
		{"GRANT ALL ON t TO u", false},
		{"REVOKE ALL ON t FROM u", false},
		{"SELECT 1; DELETE FROM t", false},
		{"  ", false},
		{"", false},
	}
	for _, tc := range cases {
		t.Run(tc.sql, func(t *testing.T) {
			if got := isSelectOnly(tc.sql); got != tc.want {
				t.Errorf("isSelectOnly(%q) = %v, want %v", tc.sql, got, tc.want)
			}
		})
	}
}

func TestSha(t *testing.T) {
	a := Sha("foo", "bar")
	b := Sha("foo", "bar")
	if a != b {
		t.Error("Sha must be deterministic")
	}
	c := Sha("foobar")
	if a == c {
		t.Error("Sha must distinguish separator boundaries")
	}
}

func TestSchemas(t *testing.T) {
	c := &Ctx{}
	defs := c.Schemas()
	if len(defs) < 8 {
		t.Errorf("expected 9 tool defs, got %d", len(defs))
	}
	names := map[string]bool{}
	for _, d := range defs {
		names[d.Name] = true
		if d.Description == "" {
			t.Errorf("tool %s missing description", d.Name)
		}
		// InputSchema must be valid JSON
		var v any
		if err := json.Unmarshal(d.InputSchema, &v); err != nil {
			t.Errorf("tool %s InputSchema invalid JSON: %v", d.Name, err)
		}
	}
	for _, want := range []string{
		"list_applied_migrations", "get_migration_file", "get_db_objects",
		"get_table_columns", "get_function_body", "query_readonly",
		"validate_sql", "propose_down_sql", "commit_down",
	} {
		if !names[want] {
			t.Errorf("missing tool: %s", want)
		}
	}
}

func TestProposeAndCommit(t *testing.T) {
	c := New(nil, "")
	input := []byte(`{"file_path":"migrations/V5.0__schedule_arrays.sql","sql":"DROP TABLE booking;"}`)
	result, err := c.Dispatch(nil, "propose_down_sql", input)
	if err != nil {
		t.Fatal(err)
	}
	m, ok := result.(map[string]string)
	if !ok || m["status"] != "staged" {
		t.Errorf("propose result = %v", result)
	}
	if c.AcceptedProposals["migrations/V5.0__schedule_arrays.sql"] != "DROP TABLE booking;" {
		t.Error("proposal not staged")
	}

	commit := []byte(`{"file_path":"migrations/V5.0__schedule_arrays.sql"}`)
	cr, err := c.Dispatch(nil, "commit_down", commit)
	if err != nil {
		t.Fatal(err)
	}
	cm, ok := cr.(map[string]string)
	if !ok || cm["status"] != "committed" {
		t.Errorf("commit result = %v", cr)
	}
}

func TestCommitWithoutProposal(t *testing.T) {
	c := New(nil, "")
	commit := []byte(`{"file_path":"migrations/V5.0.sql"}`)
	cr, err := c.Dispatch(nil, "commit_down", commit)
	if err != nil {
		t.Fatal(err)
	}
	cm, ok := cr.(map[string]string)
	if !ok || cm["error"] == "" {
		t.Errorf("expected error on commit without proposal, got %v", cr)
	}
}

func TestUnknownTool(t *testing.T) {
	c := New(nil, "")
	_, err := c.Dispatch(nil, "no_such_tool", []byte(`{}`))
	if err == nil {
		t.Error("expected error for unknown tool")
	}
}

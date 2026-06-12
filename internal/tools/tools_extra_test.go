package tools

import (
	"strings"
	"testing"
)

func TestDispatchMalformedJSON(t *testing.T) {
	c := New(nil, "")
	_, err := c.Dispatch(nil, "propose_down_sql", []byte(`{not valid`))
	if err == nil {
		t.Error("expected JSON parse error")
	}
	_, err = c.Dispatch(nil, "commit_down", []byte(`{not valid`))
	if err == nil {
		t.Error("expected JSON parse error")
	}
}

func TestProposeMultipleOverwrites(t *testing.T) {
	c := New(nil, "")
	in1 := []byte(`{"file_path":"a.sql","sql":"DROP TABLE x;"}`)
	in2 := []byte(`{"file_path":"a.sql","sql":"DROP TABLE y;"}`)
	c.Dispatch(nil, "propose_down_sql", in1)
	c.Dispatch(nil, "propose_down_sql", in2)
	if c.AcceptedProposals["a.sql"] != "DROP TABLE y;" {
		t.Errorf("overwrite failed: %q", c.AcceptedProposals["a.sql"])
	}
}

func TestSchemasHaveTypeObject(t *testing.T) {
	c := New(nil, "")
	for _, d := range c.Schemas() {
		s := string(d.InputSchema)
		if !strings.Contains(s, `"type":"object"`) {
			t.Errorf("tool %s schema missing type=object: %s", d.Name, s)
		}
	}
}

func TestIsSelectOnlyMultilineLeading(t *testing.T) {
	if !isSelectOnly("\n\t SELECT 1") {
		t.Error("isSelectOnly should accept whitespace before SELECT")
	}
	if !isSelectOnly("WITH q AS (SELECT 1) SELECT * FROM q") {
		t.Error("isSelectOnly should accept WITH")
	}
}

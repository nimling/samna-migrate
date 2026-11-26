package data

import (
	"reflect"
	"strings"
	"testing"
)

type seen struct {
	line int64
	row  string
}

func readAll(t *testing.T, body string) ([]seen, error) {
	t.Helper()
	out := []seen{}
	err := readRows(strings.NewReader(body), func(line int64, row []byte, offset int64) error {
		out = append(out, seen{line: line, row: string(row)})
		return nil
	})
	return out, err
}

func TestReadRowsArray(t *testing.T) {
	got, err := readAll(t, "\n[\n  {\"id\": 1},\n  {\n    \"id\": 2\n  }\n]\n")
	if err != nil {
		t.Fatal(err)
	}
	want := []seen{{3, `{"id": 1}`}, {4, "{\n    \"id\": 2\n  }"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("readRows array = %+v, want %+v", got, want)
	}
}

func TestReadRowsLines(t *testing.T) {
	got, err := readAll(t, "{\"id\":1}\n\n{\"id\":2}\r\n{\"id\":3}")
	if err != nil {
		t.Fatal(err)
	}
	want := []seen{{1, `{"id":1}`}, {3, `{"id":2}`}, {4, `{"id":3}`}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("readRows lines = %+v, want %+v", got, want)
	}
}

func TestReadRowsEmpty(t *testing.T) {
	for _, body := range []string{"", "  \n", "[]", "[\n]\n"} {
		got, err := readAll(t, body)
		if err != nil || len(got) != 0 {
			t.Errorf("readRows(%q) = %v %v, want no rows", body, got, err)
		}
	}
}

func TestReadRowsBrokenArray(t *testing.T) {
	_, err := readAll(t, "[\n{\"id\":1},\n{\"id\":\n")
	if err == nil || !strings.HasPrefix(err.Error(), "line ") {
		t.Errorf("readRows broken array err = %v, want a line number", err)
	}
}

func TestGetFormat(t *testing.T) {
	cases := map[string]string{
		"public.a.json":   FormatJSON,
		"public.a.jsonl":  FormatJSONL,
		"public.a.NDJSON": FormatJSONL,
		"public.a.csv":    FormatCSV,
		"public.a.sql":    FormatSQL,
		"public.a.txt":    "",
	}
	for path, want := range cases {
		got, _ := GetFormat(path)
		if got != want {
			t.Errorf("GetFormat(%q) = %q, want %q", path, got, want)
		}
	}
}

func TestStatementTarget(t *testing.T) {
	cases := map[string]string{
		`INSERT INTO "public"."person" AS t ("id") VALUES (1);`:                    "public.person",
		"insert into public.person (id) values (1);":                               "public.person",
		"UPDATE ONLY claimius.samna_user SET x = 1;":                               "claimius.samna_user",
		"delete from person where id = 1;":                                         "person",
		`DELETE FROM "we""ird"."t.x" WHERE true;`:                                  `we"ird.t.x`,
		"merge into public.person p using x on true when matched then do nothing;": "public.person",
		"SELECT 1;": "",
	}
	for stmt, want := range cases {
		if got := statementTarget(stmt); got != want {
			t.Errorf("statementTarget(%q) = %q, want %q", stmt, got, want)
		}
	}
}

func TestDiffers(t *testing.T) {
	if got := differs(nil, "t", "excluded"); got != "false" {
		t.Errorf("differs with no columns = %q", got)
	}
	got := differs([]string{"a", "b"}, "t", "excluded")
	want := `ROW(to_jsonb(t."a"), to_jsonb(t."b")) IS DISTINCT FROM ROW(to_jsonb(excluded."a"), to_jsonb(excluded."b"))`
	if got != want {
		t.Errorf("differs = %q, want %q", got, want)
	}
}

func TestValidMode(t *testing.T) {
	for _, m := range Modes {
		if !ValidMode(m) {
			t.Errorf("ValidMode(%q) = false", m)
		}
	}
	for _, m := range []string{"", "sync", "UPSERT"} {
		if ValidMode(m) {
			t.Errorf("ValidMode(%q) = true", m)
		}
	}
}

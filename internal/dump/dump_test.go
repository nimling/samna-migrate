package dump

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDetectSourceUses(t *testing.T) {
	dir := t.TempDir()
	mk := func(name, content string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(content), 0o644)
		return p
	}
	cases := []struct {
		name    string
		files   map[string]string
		want    SourceFlags
	}{
		{
			"grants and comment",
			map[string]string{"a.sql": "GRANT SELECT ON t TO u;\nCOMMENT ON TABLE t IS 'x';"},
			SourceFlags{UsesGrant: true, UsesComment: true},
		},
		{
			"policy",
			map[string]string{"a.sql": "CREATE POLICY p ON t FOR SELECT USING (true);"},
			SourceFlags{UsesPolicy: true},
		},
		{
			"row level security",
			map[string]string{"a.sql": "ALTER TABLE t ENABLE ROW LEVEL SECURITY;"},
			SourceFlags{UsesPolicy: true},
		},
		{
			"extension",
			map[string]string{"a.sql": "CREATE EXTENSION pgcrypto;"},
			SourceFlags{UsesExtension: true},
		},
		{
			"default priv",
			map[string]string{"a.sql": "ALTER DEFAULT PRIVILEGES IN SCHEMA s GRANT SELECT ON TABLES TO u;"},
			SourceFlags{UsesGrant: true, UsesDefaultPriv: true},
		},
		{
			"sequence owned",
			map[string]string{"a.sql": "ALTER SEQUENCE s OWNED BY t.id;"},
			SourceFlags{UsesSeqOwned: true},
		},
		{
			"nothing fancy",
			map[string]string{"a.sql": "SELECT 1;"},
			SourceFlags{},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			paths := []string{}
			for name, content := range tc.files {
				paths = append(paths, mk(name, content))
			}
			got, err := DetectSourceUses(paths)
			if err != nil {
				t.Fatal(err)
			}
			if *got != tc.want {
				t.Errorf("flags = %+v, want %+v", *got, tc.want)
			}
		})
	}
}

func TestQuoteIdentsCSV(t *testing.T) {
	got := quoteIdentsCSV([]string{"public", "claimius"})
	want := "'public', 'claimius'"
	if got != want {
		t.Errorf("quoteIdentsCSV: got %q want %q", got, want)
	}
}

func TestQuoteIdentsCSVQuoting(t *testing.T) {
	got := quoteIdentsCSV([]string{"o'reilly"})
	want := "'o''reilly'"
	if got != want {
		t.Errorf("quoteIdentsCSV escaping: got %q want %q", got, want)
	}
}

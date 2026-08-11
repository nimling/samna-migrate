package require

import "testing"

func TestScanStatementIgnoresLanguageColumn(t *testing.T) {
	reqExt := map[string]bool{}
	reqLang := map[string]bool{}
	reqRole := map[string]bool{}
	provLang := map[string]bool{}
	provRole := map[string]bool{}

	table := `CREATE TABLE IF NOT EXISTS claimius.analytics_event (
    id uuid PRIMARY KEY,
    language      TEXT,
    referrer      TEXT
)`
	scanStatement(table, reqExt, reqLang, reqRole, provLang, provRole)
	if len(reqLang) != 0 {
		t.Fatalf("a language column must not register a language requirement, got %v", reqLang)
	}

	fn := `CREATE OR REPLACE FUNCTION claimius.f() RETURNS void AS $$ BEGIN END; $$ LANGUAGE plpgsql`
	scanStatement(fn, reqExt, reqLang, reqRole, provLang, provRole)
	if !reqLang["plpgsql"] {
		t.Fatalf("a function body language must register, got %v", reqLang)
	}
}

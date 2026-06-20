package merge

import (
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/sqlscan"
)

const spliceFixture = `CREATE TABLE public.a (id INT);

CREATE OR REPLACE FUNCTION claimius.get_access(p_user UUID)
RETURNS TABLE (x INT) AS $func$
BEGIN
    RETURN QUERY SELECT 1; -- semicolons; inside; body
    PERFORM 'a ; quoted ; string';
END;
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION claimius.get_access(p_user UUID, p_extra INT)
RETURNS TABLE (x INT) AS $$ SELECT 1; $$ LANGUAGE sql;

CREATE TRIGGER tg_calc_access AFTER INSERT ON public.a
    FOR EACH ROW EXECUTE FUNCTION claimius.calc_object_access();

CREATE INDEX a_idx ON public.a (id);
`

func TestRemoveStatementsFunctionOverloads(t *testing.T) {
	got := spliceStatement(spliceFixture, headPattern("FUNCTION", "claimius.get_access"), "")
	if strings.Contains(got, "get_access") {
		t.Errorf("both overloads must be removed: %q", got)
	}
	if !strings.Contains(got, "CREATE TABLE public.a") {
		t.Errorf("table must survive: %q", got)
	}
	if !strings.Contains(got, "CREATE TRIGGER tg_calc_access") {
		t.Errorf("trigger must survive: %q", got)
	}
	if !strings.Contains(got, "CREATE INDEX a_idx") {
		t.Errorf("index must survive: %q", got)
	}
}

func TestRemoveStatementsTrigger(t *testing.T) {
	got := spliceStatement(spliceFixture, headPattern("TRIGGER", "tg_calc_access"), "")
	if strings.Contains(got, "CREATE TRIGGER tg_calc_access") {
		t.Errorf("trigger must be removed: %q", got)
	}
	if strings.Contains(got, "calc_object_access") {
		t.Errorf("whole trigger statement must be removed: %q", got)
	}
	if !strings.Contains(got, "get_access") {
		t.Errorf("functions must survive: %q", got)
	}
}

func TestRemoveStatementsIndex(t *testing.T) {
	got := spliceStatement(spliceFixture, headPattern("INDEX", "a_idx"), "")
	if strings.Contains(got, "a_idx") {
		t.Errorf("index must be removed: %q", got)
	}
	if !strings.Contains(got, "CREATE TABLE public.a") {
		t.Errorf("table must survive: %q", got)
	}
}

func TestStatementEndRespectsDollarQuotes(t *testing.T) {
	s := "CREATE FUNCTION f() AS $x$ body; with; semis $x$ LANGUAGE sql; SELECT 2;"
	end := sqlscan.StatementEnd(s, 0)
	if !strings.HasSuffix(s[:end], "LANGUAGE sql;") {
		t.Errorf("statement end inside dollar quotes: %q", s[:end])
	}
}

func TestStatementEndRespectsQuotesAndComments(t *testing.T) {
	s := "CREATE VIEW v AS SELECT 'a;b', /* c;d */ 1 -- e;f\n FROM t; SELECT 9;"
	end := sqlscan.StatementEnd(s, 0)
	if !strings.HasSuffix(strings.TrimSpace(s[:end]), "FROM t;") {
		t.Errorf("statement end inside quotes or comments: %q", s[:end])
	}
}

func TestHeadPatternDoesNotMatchPrefixNames(t *testing.T) {
	content := "CREATE INDEX a_idx_extra ON public.a (id);"
	got := spliceStatement(content, headPattern("INDEX", "a_idx"), "")
	if got != content {
		t.Errorf("prefix name must not match: %q", got)
	}
}

func TestSpliceStatementReplacesInPlace(t *testing.T) {
	def := "CREATE OR REPLACE FUNCTION claimius.get_access(p_user UUID, p_lvl INT)\nRETURNS TABLE (x INT) AS $live$ SELECT 2; $live$ LANGUAGE sql;"
	got := spliceStatement(spliceFixture, headPattern("FUNCTION", "claimius.get_access"), def)
	if strings.Count(got, "CREATE OR REPLACE FUNCTION claimius.get_access") != 1 {
		t.Errorf("exactly one definition must remain: %q", got)
	}
	if !strings.Contains(got, "$live$") {
		t.Errorf("live definition must be present: %q", got)
	}
	tablePos := strings.Index(got, "CREATE TABLE public.a")
	defPos := strings.Index(got, "$live$")
	trigPos := strings.Index(got, "CREATE TRIGGER tg_calc_access")
	if !(tablePos < defPos && defPos < trigPos) {
		t.Errorf("definition must land at the original position: table=%d def=%d trigger=%d", tablePos, defPos, trigPos)
	}
}

func TestSpliceStatementAppendsWhenAbsent(t *testing.T) {
	def := "CREATE OR REPLACE FUNCTION claimius.brand_new() RETURNS void AS $n$ BEGIN END $n$ LANGUAGE plpgsql;"
	got := spliceStatement(spliceFixture, headPattern("FUNCTION", "claimius.brand_new"), def)
	if !strings.HasSuffix(strings.TrimSpace(got), "LANGUAGE plpgsql;") {
		t.Errorf("new definition must append at the end: %q", got)
	}
	if !strings.Contains(got, "CREATE INDEX a_idx") {
		t.Errorf("existing content must survive: %q", got)
	}
}

package merge

import (
	"os"
	"regexp"
	"strings"

	"github.com/nimling/samna-migrate/internal/sqlscan"
)

var (
	rxStmtCreate  = regexp.MustCompile(`^(?i)CREATE\s+(?:OR\s+REPLACE\s+)?(?:UNIQUE\s+)?(?:MATERIALIZED\s+)?(?:CONSTRAINT\s+)?(FUNCTION|PROCEDURE|TABLE|VIEW|TRIGGER|TYPE|INDEX|SEQUENCE)\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:CONCURRENTLY\s+)?([a-z_0-9."]+)`)
	rxStmtAlter   = regexp.MustCompile(`^(?i)ALTER\s+(TABLE|TYPE|SEQUENCE|VIEW|INDEX|FUNCTION)\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?([a-z_0-9."]+)`)
	rxStmtDrop    = regexp.MustCompile(`^(?i)DROP\s+(FUNCTION|TABLE|VIEW|TRIGGER|TYPE|INDEX|SEQUENCE)\s+(?:IF\s+EXISTS\s+)?([a-z_0-9."]+)`)
	rxStmtGrantFn = regexp.MustCompile(`^(?i)(?:GRANT|REVOKE)\s[^;]*?\bON\s+FUNCTION\s+([a-z_0-9."]+)`)
	rxStmtComment = regexp.MustCompile(`^(?i)COMMENT\s+ON\s+FUNCTION\s+([a-z_0-9."]+)`)
)

// segment is one top level statement with its leading trivia. ident is set
// when the statement is a schema definition live state can reproduce; when
// ident is nil the statement is data or a side effect that must be preserved
// verbatim.
type segment struct {
	text  string
	ident *Ident
}

// fileSegments walks a file into ordered statements, classifying each as a
// schema definition (with its identifier) or a verbatim non schema statement.
func fileSegments(path string) ([]segment, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	content := string(b)
	var segs []segment
	i := 0
	for i < len(content) {
		segStart := i
		j := sqlscan.SkipTrivia(content, i)
		if j >= len(content) {
			break
		}
		end := sqlscan.StatementEnd(content, j)
		stmt := content[j:end]
		seg := segment{text: content[segStart:end]}
		switch {
		case rxStmtCreate.MatchString(stmt):
			m := rxStmtCreate.FindStringSubmatch(stmt)
			seg.ident = &Ident{Kind: strings.ToUpper(m[1]), Name: normalizeIdent(m[2])}
		case rxStmtAlter.MatchString(stmt):
			m := rxStmtAlter.FindStringSubmatch(stmt)
			seg.ident = &Ident{Kind: strings.ToUpper(m[1]), Name: normalizeIdent(m[2])}
		case rxStmtDrop.MatchString(stmt):
			m := rxStmtDrop.FindStringSubmatch(stmt)
			seg.ident = &Ident{Kind: strings.ToUpper(m[1]), Name: normalizeIdent(m[2])}
		case rxStmtGrantFn.MatchString(stmt):
			seg.ident = &Ident{Kind: "FUNCTION", Name: normalizeIdent(rxStmtGrantFn.FindStringSubmatch(stmt)[1])}
		case rxStmtComment.MatchString(stmt):
			seg.ident = &Ident{Kind: "FUNCTION", Name: normalizeIdent(rxStmtComment.FindStringSubmatch(stmt)[1])}
		}
		segs = append(segs, seg)
		i = end
	}
	return segs, nil
}

func normalizeIdent(s string) string {
	return strings.ToLower(strings.Trim(s, `"`))
}

// fileStatements returns the deduped schema identifiers a file defines plus
// whether it carries any non schema statement.
func fileStatements(path string) ([]Ident, bool, error) {
	segs, err := fileSegments(path)
	if err != nil {
		return nil, false, err
	}
	idents := []Ident{}
	dedup := map[string]bool{}
	nonSchema := false
	for _, s := range segs {
		if s.ident == nil {
			nonSchema = true
			continue
		}
		key := s.ident.Kind + " " + s.ident.Name
		if dedup[key] {
			continue
		}
		dedup[key] = true
		idents = append(idents, *s.ident)
	}
	return idents, nonSchema, nil
}

func identParts(ident string) (string, string) {
	name := ident
	schema := ""
	if i := strings.LastIndex(ident, "."); i >= 0 {
		schema = ident[:i]
		name = ident[i+1:]
	}
	prefix := `(?:[a-z0-9_]+\.)?`
	if schema != "" {
		prefix = `(?:` + regexp.QuoteMeta(schema) + `\.)?`
	}
	return prefix, regexp.QuoteMeta(name)
}

func auxPatterns(kind, ident string) []*regexp.Regexp {
	prefix, q := identParts(ident)
	switch strings.ToUpper(kind) {
	case "FUNCTION", "PROCEDURE":
		return []*regexp.Regexp{
			regexp.MustCompile(`(?i)GRANT\s[^;]*?\bFUNCTION\s+` + prefix + q + `\s*\(`),
			regexp.MustCompile(`(?i)REVOKE\s[^;]*?\bFUNCTION\s+` + prefix + q + `\s*\(`),
			regexp.MustCompile(`(?i)COMMENT\s+ON\s+FUNCTION\s+` + prefix + q + `\b`),
		}
	}
	return nil
}

func dependentPatterns(kind, ident string) []*regexp.Regexp {
	prefix, q := identParts(ident)
	switch strings.ToUpper(kind) {
	case "FUNCTION", "PROCEDURE":
		return []*regexp.Regexp{
			regexp.MustCompile(`(?i)CREATE\s+(?:CONSTRAINT\s+)?TRIGGER\s+[a-z0-9_"]+[^;]*?\bEXECUTE\s+(?:FUNCTION|PROCEDURE)\s+` + prefix + q + `\s*\(`),
			regexp.MustCompile(`(?i)DROP\s+FUNCTION\s+IF\s+EXISTS\s+` + prefix + q + `\b`),
		}
	}
	return nil
}

func headPattern(kind, ident string) *regexp.Regexp {
	prefix, q := identParts(ident)
	switch strings.ToUpper(kind) {
	case "FUNCTION":
		return regexp.MustCompile(`(?i)CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+` + prefix + q + `\s*\(`)
	case "PROCEDURE":
		return regexp.MustCompile(`(?i)CREATE\s+(?:OR\s+REPLACE\s+)?PROCEDURE\s+` + prefix + q + `\s*\(`)
	case "TRIGGER":
		return regexp.MustCompile(`(?i)CREATE\s+(?:CONSTRAINT\s+)?TRIGGER\s+` + q + `\b`)
	case "INDEX":
		return regexp.MustCompile(`(?i)CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?` + q + `\b`)
	case "VIEW":
		return regexp.MustCompile(`(?i)CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\s+` + prefix + q + `\b`)
	case "TABLE":
		return regexp.MustCompile(`(?i)CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?` + prefix + q + `\b`)
	case "TYPE":
		return regexp.MustCompile(`(?i)CREATE\s+TYPE\s+` + prefix + q + `\b`)
	case "SEQUENCE":
		return regexp.MustCompile(`(?i)CREATE\s+SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?` + prefix + q + `\b`)
	}
	return regexp.MustCompile(`$^`)
}

func spliceStatement(content string, head *regexp.Regexp, def string) string {
	starts := []int{}
	i := 0
	for i < len(content) {
		i = sqlscan.SkipTrivia(content, i)
		if i >= len(content) {
			break
		}
		if loc := head.FindStringIndex(content[i:]); loc != nil && loc[0] == 0 {
			starts = append(starts, i)
		}
		i = sqlscan.StatementEnd(content, i)
	}
	if len(starts) == 0 {
		if def == "" {
			return content
		}
		return strings.TrimRight(content, "\n") + "\n\n" + def + "\n"
	}
	for i := len(starts) - 1; i >= 1; i-- {
		end := sqlscan.StatementEnd(content, starts[i])
		content = strings.TrimRight(content[:starts[i]], " \t") + content[end:]
	}
	end := sqlscan.StatementEnd(content, starts[0])
	if def == "" {
		return strings.TrimRight(content[:starts[0]], " \t") + content[end:]
	}
	return content[:starts[0]] + def + content[end:]
}

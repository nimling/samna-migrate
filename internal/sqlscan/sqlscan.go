package sqlscan

import (
	"regexp"
	"strconv"
	"strings"
)

var rxDollarTag = regexp.MustCompile(`^\$[A-Za-z_0-9]*\$`)

// SkipTrivia advances past whitespace and SQL comments starting at i.
func SkipTrivia(s string, i int) int {
	for i < len(s) {
		switch {
		case s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r':
			i++
		case strings.HasPrefix(s[i:], "--"):
			nl := strings.IndexByte(s[i:], '\n')
			if nl < 0 {
				return len(s)
			}
			i += nl + 1
		case strings.HasPrefix(s[i:], "/*"):
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				return len(s)
			}
			i += 2 + end + 2
		default:
			return i
		}
	}
	return i
}

// StatementEnd returns the index just past the terminating semicolon of the
// statement beginning at start, honoring string literals, dollar quoted
// bodies, and comments so semicolons inside them never split a statement.
func StatementEnd(s string, start int) int {
	i := start
	for i < len(s) {
		switch {
		case strings.HasPrefix(s[i:], "--"):
			nl := strings.IndexByte(s[i:], '\n')
			if nl < 0 {
				return len(s)
			}
			i += nl + 1
		case strings.HasPrefix(s[i:], "/*"):
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				return len(s)
			}
			i += 2 + end + 2
		case s[i] == '\'':
			j := i + 1
			for j < len(s) {
				if s[j] == '\'' {
					if j+1 < len(s) && s[j+1] == '\'' {
						j += 2
						continue
					}
					j++
					break
				}
				j++
			}
			i = j
		case s[i] == '$':
			tag := rxDollarTag.FindString(s[i:])
			if tag == "" {
				i++
				continue
			}
			closing := strings.Index(s[i+len(tag):], tag)
			if closing < 0 {
				return len(s)
			}
			i += len(tag) + closing + len(tag)
		case s[i] == ';':
			return i + 1
		default:
			i++
		}
	}
	return len(s)
}

// Statements splits content into top level statement bodies, each trimmed of
// its leading trivia. Trailing trivia after the final statement is dropped.
func Statements(content string) []string {
	out := []string{}
	i := 0
	for i < len(content) {
		j := SkipTrivia(content, i)
		if j >= len(content) {
			break
		}
		end := StatementEnd(content, j)
		out = append(out, content[j:end])
		i = end
	}
	return out
}

type Stat struct {
	Key string
	Val string
}

type Object struct {
	Kind  string
	Name  string
	Line  int
	SQL   string
	Stats []Stat
}

var (
	reFunction = regexp.MustCompile(`(?is)^\s*CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+([\w."]+)`)
	reTable    = regexp.MustCompile(`(?is)^\s*CREATE\s+(?:UNLOGGED\s+|TEMP\s+|TEMPORARY\s+|GLOBAL\s+|LOCAL\s+)*TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w."]+)`)
	reIndex    = regexp.MustCompile(`(?is)^\s*CREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?([\w."]+)\s+ON\s+(?:ONLY\s+)?([\w."]+)`)
	reTrigger  = regexp.MustCompile(`(?is)^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\s+([\w."]+)`)
	reView     = regexp.MustCompile(`(?is)^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w."]+)`)
	reType     = regexp.MustCompile(`(?is)^\s*CREATE\s+TYPE\s+([\w."]+)\s+AS\s+(ENUM|RANGE)?`)
	reSequence = regexp.MustCompile(`(?is)^\s*CREATE\s+(?:TEMP\s+|TEMPORARY\s+)?SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w."]+)`)
	rePolicy   = regexp.MustCompile(`(?is)^\s*CREATE\s+POLICY\s+([\w."]+)\s+ON\s+([\w."]+)`)
	reSchema   = regexp.MustCompile(`(?is)^\s*CREATE\s+SCHEMA\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w."]+)`)
	reDomain   = regexp.MustCompile(`(?is)^\s*CREATE\s+DOMAIN\s+([\w."]+)`)
	reAlter    = regexp.MustCompile(`(?is)^\s*ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?([\w."]+)`)
	reDrop     = regexp.MustCompile(`(?is)^\s*DROP\s+(\w+)\s+(?:CONCURRENTLY\s+)?(?:IF\s+EXISTS\s+)?([\w."]+)`)
	reInsert   = regexp.MustCompile(`(?is)^\s*INSERT\s+INTO\s+([\w."]+)`)
	reDo       = regexp.MustCompile(`(?is)^\s*DO[\s$]`)

	reReturns = regexp.MustCompile(`(?is)\bRETURNS\s+(SETOF\s+)?([\w."]+)`)
	reLang    = regexp.MustCompile(`(?is)\bLANGUAGE\s+(\w+)`)
	reVol     = regexp.MustCompile(`(?is)\b(IMMUTABLE|STABLE|VOLATILE)\b`)
	reSec     = regexp.MustCompile(`(?is)\bSECURITY\s+(DEFINER|INVOKER)\b`)
	reMethod  = regexp.MustCompile(`(?is)\bUSING\s+(\w+)`)
	reTrigOn  = regexp.MustCompile(`(?is)\bON\s+([\w."]+)`)
	reTrigFn  = regexp.MustCompile(`(?is)\bEXECUTE\s+(?:PROCEDURE|FUNCTION)\s+([\w."]+)`)
)

// Scan returns one Object per recognized top level statement, each carrying a
// kind, qualified name, source line, and a set of statically derived stats.
func Scan(content string) []Object {
	var objs []Object
	i := 0
	for i < len(content) {
		j := SkipTrivia(content, i)
		if j >= len(content) {
			break
		}
		end := StatementEnd(content, j)
		o, ok := classify(content[j:end])
		if ok {
			o.Line = strings.Count(content[:j], "\n") + 1
			o.SQL = strings.TrimSpace(content[j:end])
			o.Stats = append(o.Stats, Stat{"at", strconv.Itoa(o.Line)})
			objs = append(objs, o)
		}
		i = end
	}
	return objs
}

func classify(text string) (Object, bool) {
	sh := shell(text)
	common := []Stat{
		{"lines", strconv.Itoa(strings.Count(strings.TrimRight(text, "\n"), "\n") + 1)},
		{"bytes", strconv.Itoa(len(strings.TrimSpace(text)))},
	}

	if m := reFunction.FindStringSubmatchIndex(sh); m != nil {
		name := sh[m[2]:m[3]]
		args, _ := parenAfter(sh, m[1])
		params, outs := countParams(args)
		stats := []Stat{{"params", strconv.Itoa(params)}}
		if outs > 0 {
			stats = append(stats, Stat{"out", strconv.Itoa(outs)})
		}
		if r := reReturns.FindStringSubmatch(sh); r != nil {
			ret := strings.ToUpper(r[2])
			if strings.TrimSpace(r[1]) != "" {
				ret = "SETOF"
			}
			stats = append(stats, Stat{"returns", ret})
		}
		if l := reLang.FindStringSubmatch(sh); l != nil {
			stats = append(stats, Stat{"lang", strings.ToLower(l[1])})
		}
		if v := reVol.FindStringSubmatch(sh); v != nil {
			stats = append(stats, Stat{"vol", strings.ToLower(v[1])})
		}
		if s := reSec.FindStringSubmatch(sh); s != nil {
			stats = append(stats, Stat{"sec", strings.ToLower(s[1])})
		}
		if strings.Contains(strings.ToUpper(sh), " STRICT") {
			stats = append(stats, Stat{"strict", "yes"})
		}
		stats = append(stats, Stat{"body", strconv.Itoa(bodyLines(text))})
		return Object{Kind: "function", Name: name, Stats: append(stats, common...)}, true
	}

	if m := reIndex.FindStringSubmatchIndex(sh); m != nil {
		name := sh[m[4]:m[5]]
		table := sh[m[6]:m[7]]
		cols, _ := parenAfter(sh, m[7])
		stats := []Stat{
			{"on", table},
			{"cols", strconv.Itoa(len(splitTop(cols)))},
		}
		if m[2] >= 0 && strings.TrimSpace(sh[m[2]:m[3]]) != "" {
			stats = append(stats, Stat{"unique", "yes"})
		}
		if mm := reMethod.FindStringSubmatch(sh); mm != nil {
			stats = append(stats, Stat{"method", strings.ToLower(mm[1])})
		}
		if strings.Contains(strings.ToUpper(sh), " WHERE ") {
			stats = append(stats, Stat{"partial", "yes"})
		}
		return Object{Kind: "index", Name: name, Stats: append(stats, common...)}, true
	}

	if m := reTable.FindStringSubmatchIndex(sh); m != nil {
		name := sh[m[2]:m[3]]
		body, _ := parenAfter(sh, m[1])
		cols, pk, fk, checks := countColumns(body)
		stats := []Stat{
			{"cols", strconv.Itoa(cols)},
			{"pk", yn(pk > 0)},
			{"fk", strconv.Itoa(fk)},
			{"checks", strconv.Itoa(checks)},
		}
		return Object{Kind: "table", Name: name, Stats: append(stats, common...)}, true
	}

	if m := reTrigger.FindStringSubmatch(sh); m != nil {
		up := strings.ToUpper(sh)
		stats := []Stat{}
		if on := reTrigOn.FindStringSubmatch(sh); on != nil {
			stats = append(stats, Stat{"on", on[1]})
		}
		stats = append(stats, Stat{"when", triggerWhen(up)})
		stats = append(stats, Stat{"events", triggerEvents(up)})
		stats = append(stats, Stat{"level", triggerLevel(up)})
		if fn := reTrigFn.FindStringSubmatch(sh); fn != nil {
			stats = append(stats, Stat{"fn", fn[1]})
		}
		return Object{Kind: "trigger", Name: m[1], Stats: append(stats, common...)}, true
	}

	if m := reView.FindStringSubmatchIndex(sh); m != nil {
		name := sh[m[4]:m[5]]
		stats := []Stat{}
		if m[2] >= 0 && strings.TrimSpace(sh[m[2]:m[3]]) != "" {
			stats = append(stats, Stat{"materialized", "yes"})
		}
		return Object{Kind: "view", Name: name, Stats: append(stats, common...)}, true
	}

	if m := reType.FindStringSubmatchIndex(sh); m != nil {
		name := sh[m[2]:m[3]]
		shape := ""
		if m[4] >= 0 {
			shape = strings.ToLower(strings.TrimSpace(sh[m[4]:m[5]]))
		}
		body, _ := parenAfter(sh, m[1])
		if shape == "" {
			shape = "composite"
		}
		stats := []Stat{{"shape", shape}}
		if n := len(splitTop(body)); n > 0 && strings.TrimSpace(body) != "" {
			stats = append(stats, Stat{"values", strconv.Itoa(n)})
		}
		return Object{Kind: "type", Name: name, Stats: append(stats, common...)}, true
	}

	if m := reSequence.FindStringSubmatch(sh); m != nil {
		return Object{Kind: "sequence", Name: m[1], Stats: common}, true
	}

	if m := rePolicy.FindStringSubmatch(sh); m != nil {
		return Object{Kind: "policy", Name: m[1], Stats: append([]Stat{{"on", m[2]}}, common...)}, true
	}

	if m := reSchema.FindStringSubmatch(sh); m != nil {
		return Object{Kind: "schema", Name: m[1], Stats: common}, true
	}

	if m := reDomain.FindStringSubmatch(sh); m != nil {
		return Object{Kind: "domain", Name: m[1], Stats: common}, true
	}

	if m := reAlter.FindStringSubmatch(sh); m != nil {
		up := strings.ToUpper(sh)
		stats := []Stat{}
		if n := strings.Count(up, " ADD "); n > 0 {
			stats = append(stats, Stat{"adds", strconv.Itoa(n)})
		}
		if n := strings.Count(up, " DROP "); n > 0 {
			stats = append(stats, Stat{"drops", strconv.Itoa(n)})
		}
		if n := strings.Count(up, "ALTER COLUMN"); n > 0 {
			stats = append(stats, Stat{"alters", strconv.Itoa(n)})
		}
		return Object{Kind: "alter", Name: m[1], Stats: append(stats, common...)}, true
	}

	if m := reDrop.FindStringSubmatch(sh); m != nil {
		return Object{Kind: "drop", Name: m[2], Stats: append([]Stat{{"what", strings.ToLower(m[1])}}, common...)}, true
	}

	if m := reInsert.FindStringSubmatch(sh); m != nil {
		up := strings.ToUpper(sh)
		stats := []Stat{}
		if idx := strings.Index(up, " VALUES"); idx >= 0 {
			rows := 0
			for _, p := range splitTop(sh[idx+len(" VALUES"):]) {
				if strings.Contains(p, "(") {
					rows++
				}
			}
			stats = append(stats, Stat{"rows", strconv.Itoa(rows)})
		} else if strings.Contains(up, "SELECT") {
			stats = append(stats, Stat{"rows", "select"})
		}
		return Object{Kind: "insert", Name: m[1], Stats: append(stats, common...)}, true
	}

	if reDo.MatchString(sh) {
		stats := []Stat{}
		if l := reLang.FindStringSubmatch(sh); l != nil {
			stats = append(stats, Stat{"lang", strings.ToLower(l[1])})
		}
		stats = append(stats, Stat{"body", strconv.Itoa(bodyLines(text))})
		return Object{Kind: "do", Name: "", Stats: append(stats, common...)}, true
	}

	return Object{}, false
}

func countParams(args string) (int, int) {
	parts := splitTop(args)
	if len(parts) == 1 && strings.TrimSpace(parts[0]) == "" {
		return 0, 0
	}
	outs := 0
	for _, p := range parts {
		head := strings.ToUpper(strings.TrimSpace(p))
		if strings.HasPrefix(head, "OUT ") || strings.HasPrefix(head, "INOUT ") {
			outs++
		}
	}
	return len(parts), outs
}

func countColumns(body string) (cols, pk, fk, checks int) {
	for _, p := range splitTop(body) {
		u := strings.ToUpper(strings.TrimSpace(p))
		switch {
		case u == "":
		case strings.HasPrefix(u, "PRIMARY KEY"):
			pk++
		case strings.HasPrefix(u, "FOREIGN KEY"):
			fk++
		case strings.HasPrefix(u, "UNIQUE"):
		case strings.HasPrefix(u, "EXCLUDE"):
		case strings.HasPrefix(u, "LIKE "):
		case strings.HasPrefix(u, "CHECK"):
			checks++
		case strings.HasPrefix(u, "CONSTRAINT"):
			if strings.Contains(u, "FOREIGN KEY") || strings.Contains(u, "REFERENCES") {
				fk++
			}
			if strings.Contains(u, "PRIMARY KEY") {
				pk++
			}
			if strings.Contains(u, "CHECK") {
				checks++
			}
		default:
			cols++
			if strings.Contains(u, "REFERENCES") {
				fk++
			}
			if strings.Contains(u, "PRIMARY KEY") {
				pk++
			}
		}
	}
	return cols, pk, fk, checks
}

func triggerWhen(up string) string {
	switch {
	case strings.Contains(up, "INSTEAD OF"):
		return "instead"
	case strings.Contains(up, " AFTER "):
		return "after"
	case strings.Contains(up, " BEFORE "):
		return "before"
	}
	return ""
}

func triggerEvents(up string) string {
	var ev []string
	for _, e := range []string{"INSERT", "UPDATE", "DELETE", "TRUNCATE"} {
		if strings.Contains(up, e) {
			ev = append(ev, strings.ToLower(e))
		}
	}
	return strings.Join(ev, ",")
}

func triggerLevel(up string) string {
	if strings.Contains(up, "FOR EACH STATEMENT") {
		return "statement"
	}
	if strings.Contains(up, "FOR EACH ROW") {
		return "row"
	}
	return ""
}

func yn(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func bodyLines(text string) int {
	i := strings.IndexByte(text, '$')
	for i >= 0 && i < len(text) {
		tag := rxDollarTag.FindString(text[i:])
		if tag == "" {
			next := strings.IndexByte(text[i+1:], '$')
			if next < 0 {
				return 0
			}
			i = i + 1 + next
			continue
		}
		rest := text[i+len(tag):]
		end := strings.Index(rest, tag)
		if end < 0 {
			return 0
		}
		return strings.Count(rest[:end], "\n")
	}
	return 0
}

func parenAfter(s string, from int) (string, int) {
	open := strings.IndexByte(s[from:], '(')
	if open < 0 {
		return "", -1
	}
	open += from
	depth := 0
	for i := open; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return s[open+1 : i], i + 1
			}
		}
	}
	return s[open+1:], len(s)
}

func splitTop(s string) []string {
	var out []string
	depth := 0
	start := 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(', '[':
			depth++
		case ')', ']':
			if depth > 0 {
				depth--
			}
		case ',':
			if depth == 0 {
				out = append(out, strings.TrimSpace(s[start:i]))
				start = i + 1
			}
		}
	}
	out = append(out, strings.TrimSpace(s[start:]))
	return out
}

func shell(text string) string {
	var b strings.Builder
	i := 0
	for i < len(text) {
		c := text[i]
		if c == '$' {
			if tag := rxDollarTag.FindString(text[i:]); tag != "" {
				i += len(tag)
				for i < len(text) {
					if strings.HasPrefix(text[i:], tag) {
						i += len(tag)
						break
					}
					i++
				}
				b.WriteByte(' ')
				continue
			}
		}
		if c == '\'' {
			i++
			for i < len(text) {
				if text[i] == '\'' {
					if i+1 < len(text) && text[i+1] == '\'' {
						i += 2
						continue
					}
					i++
					break
				}
				i++
			}
			b.WriteByte(' ')
			continue
		}
		b.WriteByte(c)
		i++
	}
	return b.String()
}

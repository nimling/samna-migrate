package sqlscan

import (
	"regexp"
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

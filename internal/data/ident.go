package data

import (
	"path/filepath"
	"strings"
)

type Table struct {
	Schema string
	Name   string
}

const (
	FormatJSON  = "json"
	FormatJSONL = "jsonl"
	FormatCSV   = "csv"
	FormatSQL   = "sql"
)

var Formats = []string{FormatJSON, FormatJSONL, FormatCSV, FormatSQL}

var formatOfExt = map[string]string{
	".json":   FormatJSON,
	".jsonl":  FormatJSONL,
	".ndjson": FormatJSONL,
	".csv":    FormatCSV,
	".sql":    FormatSQL,
}

func (t Table) Qualified() string {
	return t.Schema + "." + t.Name
}

func (t Table) Quoted() string {
	return QuoteIdent(t.Schema) + "." + QuoteIdent(t.Name)
}

func (t Table) FileName(format string) string {
	return t.Schema + "." + t.Name + "." + format
}

func GetFormat(path string) (string, bool) {
	format, ok := formatOfExt[strings.ToLower(filepath.Ext(path))]
	return format, ok
}

func ParseTable(qualified string) (Table, bool) {
	i := strings.Index(qualified, ".")
	if i <= 0 || i == len(qualified)-1 {
		return Table{}, false
	}
	return Table{Schema: qualified[:i], Name: qualified[i+1:]}, true
}

func QuoteIdent(id string) string {
	return `"` + strings.ReplaceAll(id, `"`, `""`) + `"`
}

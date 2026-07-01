package data

import "strings"

type Table struct {
	Schema string
	Name   string
}

func (t Table) Qualified() string {
	return t.Schema + "." + t.Name
}

func (t Table) Quoted() string {
	return QuoteIdent(t.Schema) + "." + QuoteIdent(t.Name)
}

func (t Table) FileName() string {
	return t.Schema + "." + t.Name + ".json"
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

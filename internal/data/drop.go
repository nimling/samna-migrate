package data

import (
	"sort"
	"strings"
)

type DropObj struct {
	Kind  string
	Ident string
	SQL   string
}

type DropPlan struct {
	Schemas    []string
	Objects    []DropObj
	Extensions []string
}

func (p *DropPlan) Empty() bool {
	return len(p.Schemas) == 0 && len(p.Objects) == 0 && len(p.Extensions) == 0
}

var dropOrder = map[string]int{
	"view":     0,
	"table":    1,
	"sequence": 2,
	"function": 3,
	"type":     4,
	"enum":     4,
}

func PlanDrop(objects map[string]string, schemas []string) *DropPlan {
	plan := &DropPlan{}
	public := false
	for _, s := range schemas {
		if s == "public" {
			public = true
			continue
		}
		plan.Schemas = append(plan.Schemas, s)
	}
	sort.Strings(plan.Schemas)
	if !public {
		return plan
	}
	for id := range objects {
		parts := strings.SplitN(id, " ", 2)
		if len(parts) != 2 {
			continue
		}
		kind, rest := parts[0], parts[1]
		if _, ok := dropOrder[kind]; !ok {
			continue
		}
		schema, tail := splitSchema(rest)
		if schema != "public" {
			continue
		}
		plan.Objects = append(plan.Objects, DropObj{Kind: kind, Ident: rest, SQL: dropSQL(kind, schema, tail)})
	}
	sort.SliceStable(plan.Objects, func(i, j int) bool {
		oi, oj := dropOrder[plan.Objects[i].Kind], dropOrder[plan.Objects[j].Kind]
		if oi != oj {
			return oi < oj
		}
		return plan.Objects[i].Ident < plan.Objects[j].Ident
	})
	return plan
}

func splitSchema(rest string) (string, string) {
	i := strings.Index(rest, ".")
	if i < 0 {
		return "", rest
	}
	return rest[:i], rest[i+1:]
}

func dropSQL(kind, schema, tail string) string {
	q := QuoteIdent(schema) + "."
	switch kind {
	case "view":
		return "DROP VIEW IF EXISTS " + q + QuoteIdent(tail) + " CASCADE;"
	case "table":
		return "DROP TABLE IF EXISTS " + q + QuoteIdent(tail) + " CASCADE;"
	case "sequence":
		return "DROP SEQUENCE IF EXISTS " + q + QuoteIdent(tail) + " CASCADE;"
	case "function":
		name, args := splitFuncSig(tail)
		return "DROP FUNCTION IF EXISTS " + q + QuoteIdent(name) + "(" + args + ") CASCADE;"
	case "type", "enum":
		return "DROP TYPE IF EXISTS " + q + QuoteIdent(tail) + " CASCADE;"
	}
	return ""
}

func splitFuncSig(tail string) (string, string) {
	i := strings.Index(tail, "(")
	if i < 0 {
		return tail, ""
	}
	return tail[:i], strings.TrimSuffix(tail[i+1:], ")")
}

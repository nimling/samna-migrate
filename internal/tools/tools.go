package tools

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
)

// Ctx carries the smig internals the tools need.
type Ctx struct {
	DB    *db.DB
	DBDir string
	// AcceptedProposals[file_path] = sql
	AcceptedProposals map[string]string
}

func New(d *db.DB, dbDir string) *Ctx {
	return &Ctx{DB: d, DBDir: dbDir, AcceptedProposals: map[string]string{}}
}

// Schemas returns the tool definitions for the Anthropic Messages API.
func (c *Ctx) Schemas() []ToolDef {
	return []ToolDef{
		{
			Name:        "list_applied_migrations",
			Description: "List applied migration rows in descending applied_position order. Returns id, file_path, applied_at, applied_sha256, step_type.",
			InputSchema: jsonSchema(map[string]any{
				"type":       "object",
				"properties": map[string]any{"limit": map[string]any{"type": "integer", "default": 20}},
			}),
		},
		{
			Name:        "get_migration_file",
			Description: "Read the forward SQL of a migration by its samna_migrate.file.file_path (e.g. migrations/V5.0__schedule_arrays.sql).",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"file_path"},
				"properties": map[string]any{
					"file_path": map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "get_db_objects",
			Description: "List database objects (tables, functions, types) in a schema. Returns object_type, name.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"schema"},
				"properties": map[string]any{
					"schema": map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "get_table_columns",
			Description: "List columns of a table. Returns name, data_type, is_nullable, column_default.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"schema", "table"},
				"properties": map[string]any{
					"schema": map[string]any{"type": "string"},
					"table":  map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "get_function_body",
			Description: "Return pg_get_functiondef for a function.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"schema", "name"},
				"properties": map[string]any{
					"schema": map[string]any{"type": "string"},
					"name":   map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "query_readonly",
			Description: "Execute a single SELECT statement and return rows. DML and DDL are rejected.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"sql"},
				"properties": map[string]any{
					"sql": map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "validate_sql",
			Description: "Validate SQL by running it inside BEGIN; ... ROLLBACK; and reporting parse or plan errors.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"sql"},
				"properties": map[string]any{
					"sql": map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "propose_down_sql",
			Description: "Stage a down SQL proposal for a given forward migration file_path. Does not execute. Multiple proposals overwrite.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"file_path", "sql"},
				"properties": map[string]any{
					"file_path": map[string]any{"type": "string"},
					"sql":       map[string]any{"type": "string"},
				},
			}),
		},
		{
			Name:        "commit_down",
			Description: "Confirm the staged down proposal is final for this file_path. Signals the agent loop to exit and let the executor run the SQL.",
			InputSchema: jsonSchema(map[string]any{
				"type":     "object",
				"required": []string{"file_path"},
				"properties": map[string]any{
					"file_path": map[string]any{"type": "string"},
				},
			}),
		},
	}
}

type ToolDef struct {
	Name        string
	Description string
	InputSchema json.RawMessage
}

// Dispatch runs the named tool. Returns a JSON-stringifiable result or an error.
func (c *Ctx) Dispatch(ctx context.Context, name string, input json.RawMessage) (any, error) {
	switch name {
	case "list_applied_migrations":
		var args struct {
			Limit int `json:"limit"`
		}
		_ = json.Unmarshal(input, &args)
		if args.Limit == 0 {
			args.Limit = 20
		}
		rows, err := c.DB.Pool.Query(ctx, `
			SELECT f.id, f.file_path, f.applied_at, f.applied_sha256, f.step_type, f.applied_position
			FROM samna_migrate.file f
			WHERE f.state = 'applied'
			ORDER BY f.applied_position DESC NULLS LAST
			LIMIT $1`, args.Limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []map[string]any
		for rows.Next() {
			var id int
			var fp, sha, stype string
			var appliedAt any
			var pos *int
			if err := rows.Scan(&id, &fp, &appliedAt, &sha, &stype, &pos); err != nil {
				return nil, err
			}
			out = append(out, map[string]any{
				"id":               id,
				"file_path":        fp,
				"applied_at":       appliedAt,
				"applied_sha256":   sha,
				"step_type":        stype,
				"applied_position": pos,
			})
		}
		return out, nil

	case "get_migration_file":
		var args struct {
			FilePath string `json:"file_path"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		abs := filepath.Join(c.DBDir, args.FilePath)
		b, err := os.ReadFile(abs)
		if err != nil {
			return nil, err
		}
		return map[string]any{"file_path": args.FilePath, "sql": string(b)}, nil

	case "get_db_objects":
		var args struct {
			Schema string `json:"schema"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		rows, err := c.DB.Pool.Query(ctx, `
			SELECT 'table'::text, table_name FROM information_schema.tables WHERE table_schema = $1
			UNION ALL
			SELECT 'function'::text, p.proname FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname = $1
			UNION ALL
			SELECT 'type'::text, t.typname FROM pg_type t JOIN pg_namespace n ON t.typnamespace = n.oid WHERE n.nspname = $1 AND t.typtype = 'e'
			ORDER BY 1, 2`, args.Schema)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []map[string]string
		for rows.Next() {
			var ot, n string
			if err := rows.Scan(&ot, &n); err != nil {
				return nil, err
			}
			out = append(out, map[string]string{"object_type": ot, "name": n})
		}
		return out, nil

	case "get_table_columns":
		var args struct {
			Schema string `json:"schema"`
			Table  string `json:"table"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		rows, err := c.DB.Pool.Query(ctx, `
			SELECT column_name, data_type, is_nullable, COALESCE(column_default, '')
			FROM information_schema.columns
			WHERE table_schema = $1 AND table_name = $2
			ORDER BY ordinal_position`, args.Schema, args.Table)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var out []map[string]string
		for rows.Next() {
			var name, dt, nn, def string
			if err := rows.Scan(&name, &dt, &nn, &def); err != nil {
				return nil, err
			}
			out = append(out, map[string]string{
				"name": name, "data_type": dt, "is_nullable": nn, "column_default": def,
			})
		}
		return out, nil

	case "get_function_body":
		var args struct {
			Schema string `json:"schema"`
			Name   string `json:"name"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		var body string
		err := c.DB.Pool.QueryRow(ctx, `
			SELECT pg_get_functiondef(p.oid)
			FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
			WHERE n.nspname = $1 AND p.proname = $2
			LIMIT 1`, args.Schema, args.Name).Scan(&body)
		if err != nil {
			return map[string]string{"error": err.Error()}, nil
		}
		return map[string]string{"body": body}, nil

	case "query_readonly":
		var args struct {
			SQL string `json:"sql"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		if !isSelectOnly(args.SQL) {
			return map[string]string{"error": "only SELECT statements are permitted"}, nil
		}
		rows, err := c.DB.Pool.Query(ctx, args.SQL)
		if err != nil {
			return map[string]string{"error": err.Error()}, nil
		}
		defer rows.Close()
		out := []map[string]any{}
		fds := rows.FieldDescriptions()
		for rows.Next() {
			vals, err := rows.Values()
			if err != nil {
				return nil, err
			}
			row := map[string]any{}
			for i, fd := range fds {
				row[string(fd.Name)] = vals[i]
			}
			out = append(out, row)
		}
		return out, nil

	case "validate_sql":
		var args struct {
			SQL string `json:"sql"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		tx, err := c.DB.Pool.Begin(ctx)
		if err != nil {
			return nil, err
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, args.SQL); err != nil {
			return map[string]any{"ok": false, "error": err.Error()}, nil
		}
		return map[string]any{"ok": true}, nil

	case "propose_down_sql":
		var args struct {
			FilePath string `json:"file_path"`
			SQL      string `json:"sql"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		c.AcceptedProposals[args.FilePath] = args.SQL
		return map[string]string{"status": "staged"}, nil

	case "commit_down":
		var args struct {
			FilePath string `json:"file_path"`
		}
		if err := json.Unmarshal(input, &args); err != nil {
			return nil, err
		}
		if _, ok := c.AcceptedProposals[args.FilePath]; !ok {
			return map[string]string{"error": "no proposal staged for file_path"}, nil
		}
		return map[string]string{"status": "committed", "file_path": args.FilePath}, nil
	}
	return nil, fmt.Errorf("unknown tool: %s", name)
}

var rxStmt = regexp.MustCompile(`(?i)\s*\b(insert|update|delete|truncate|drop|alter|create|grant|revoke)\b`)

func isSelectOnly(s string) bool {
	low := strings.TrimSpace(strings.ToLower(s))
	if !(strings.HasPrefix(low, "select") || strings.HasPrefix(low, "with") || strings.HasPrefix(low, "explain")) {
		return false
	}
	return !rxStmt.MatchString(s)
}

// Sha returns a stable sha for the prompt parts the agent saw.
func Sha(parts ...string) string {
	h := sha256.New()
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

func jsonSchema(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

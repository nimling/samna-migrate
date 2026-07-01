package data

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
)

func InsertFile(ctx context.Context, d *db.DB, t Table, path string, noTriggers bool) (int64, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	cols, err := insertableColumns(ctx, d, t)
	if err != nil {
		return 0, err
	}
	if len(cols) == 0 {
		return 0, fmt.Errorf("%s has no insertable columns", t.Qualified())
	}
	list := make([]string, len(cols))
	for i, c := range cols {
		list[i] = QuoteIdent(c)
	}
	colList := strings.Join(list, ", ")

	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if noTriggers {
		if _, err := tx.Exec(ctx, fmt.Sprintf("ALTER TABLE %s DISABLE TRIGGER USER", t.Quoted())); err != nil {
			return 0, err
		}
	}
	tag, err := tx.Exec(ctx, fmt.Sprintf(
		`INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_recordset(NULL::%s, $1::jsonb)`,
		t.Quoted(), colList, colList, t.Quoted()), string(raw))
	if err != nil {
		return 0, fmt.Errorf("insert into %s: %w", t.Qualified(), err)
	}
	if noTriggers {
		if _, err := tx.Exec(ctx, fmt.Sprintf("ALTER TABLE %s ENABLE TRIGGER USER", t.Quoted())); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

func insertableColumns(ctx context.Context, d *db.DB, t Table) ([]string, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT a.attname
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2
		  AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
		ORDER BY a.attnum`, t.Schema, t.Name)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

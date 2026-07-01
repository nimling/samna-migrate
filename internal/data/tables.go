package data

import (
	"context"

	"github.com/nimling/samna-migrate/internal/db"
)

func Tables(ctx context.Context, d *db.DB, schemas []string) ([]Table, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT n.nspname, c.relname
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind = 'r' AND n.nspname = ANY($1)
		ORDER BY n.nspname, c.relname`, schemas)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Table{}
	for rows.Next() {
		var t Table
		if err := rows.Scan(&t.Schema, &t.Name); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func TableExists(ctx context.Context, d *db.DB, t Table) (bool, error) {
	var n int
	err := d.Pool.QueryRow(ctx, `
		SELECT 1
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind = 'r' AND n.nspname = $1 AND c.relname = $2`,
		t.Schema, t.Name).Scan(&n)
	if err != nil {
		return false, nil
	}
	return n == 1, nil
}

package data

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nimling/samna-migrate/internal/db"
)

func DumpTable(ctx context.Context, d *db.DB, t Table, outDir string) (int, string, error) {
	var count int
	var body string
	q := fmt.Sprintf(`
		SELECT jsonb_array_length(j), jsonb_pretty(j)
		FROM (SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x::text), '[]'::jsonb) AS j FROM %s x) s`,
		t.Quoted())
	if err := d.Pool.QueryRow(ctx, q).Scan(&count, &body); err != nil {
		return 0, "", err
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return 0, "", err
	}
	path := filepath.Join(outDir, t.FileName())
	if err := os.WriteFile(path, []byte(body+"\n"), 0o644); err != nil {
		return 0, "", err
	}
	return count, path, nil
}

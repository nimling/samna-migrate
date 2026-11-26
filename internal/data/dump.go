package data

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
)

func DumpTable(ctx context.Context, d *db.DB, t Table, outDir string, in Options) (int64, string, error) {
	if in.Format == "" {
		in.Format = FormatJSON
	}
	if in.Mode == "" {
		in.Mode = ModeInsert
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return 0, "", err
	}
	path := filepath.Join(outDir, t.FileName(in.Format))
	if in.Format == FormatJSON {
		var count int64
		var body string
		q := fmt.Sprintf(`
		SELECT jsonb_array_length(j), jsonb_pretty(j)
		FROM (SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x::text), '[]'::jsonb) AS j FROM %s x) s`,
			t.Quoted())
		if err := d.Pool.QueryRow(ctx, q).Scan(&count, &body); err != nil {
			return 0, "", err
		}
		if err := os.WriteFile(path, []byte(body+"\n"), 0o644); err != nil {
			return 0, "", err
		}
		return count, path, nil
	}

	f, err := os.Create(path)
	if err != nil {
		return 0, "", err
	}
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	var count int64
	switch in.Format {
	case FormatJSONL:
		count, err = dumpJSONL(ctx, d, t, w)
	case FormatCSV:
		count, err = dumpCSV(ctx, d, t, w)
	case FormatSQL:
		count, err = dumpSQL(ctx, d, t, w, in)
	default:
		err = fmt.Errorf("format is %s, not %s", strings.Join(Formats, ", "), in.Format)
	}
	if err != nil {
		return 0, path, err
	}
	if err := w.Flush(); err != nil {
		return 0, path, err
	}
	return count, path, f.Close()
}

func dumpJSONL(ctx context.Context, d *db.DB, t Table, w *bufio.Writer) (int64, error) {
	rows, err := d.Pool.Query(ctx, fmt.Sprintf(`SELECT to_jsonb(x)::text FROM %s x ORDER BY x::text`, t.Quoted()))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var count int64
	for rows.Next() {
		var line []byte
		if err := rows.Scan(&line); err != nil {
			return count, err
		}
		w.Write(line)
		w.WriteByte('\n')
		count++
	}
	return count, rows.Err()
}

func dumpCSV(ctx context.Context, d *db.DB, t Table, w *bufio.Writer) (int64, error) {
	conn, err := d.Pool.Acquire(ctx)
	if err != nil {
		return 0, err
	}
	defer conn.Release()
	tag, err := conn.Conn().PgConn().CopyTo(ctx, w, fmt.Sprintf(
		`COPY (SELECT * FROM %s x ORDER BY x::text) TO STDOUT (FORMAT csv, HEADER true)`, t.Quoted()))
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}

func dumpSQL(ctx context.Context, d *db.DB, t Table, w *bufio.Writer, in Options) (int64, error) {
	if in.Mode == ModeCreate {
		return 0, fmt.Errorf("mode create refuses a row that exists and differs, which a sql statement cannot say; dump the sql with another mode, or dump json and insert it with --mode=create")
	}
	s, err := getShape(ctx, d, t, in)
	if err != nil {
		return 0, err
	}
	cols := s.insertable()
	values := make([]string, len(cols))
	for i, c := range cols {
		values[i] = fmt.Sprintf("quote_nullable(x.%s) || %s", QuoteIdent(c), quoteLiteral("::"+s.typeOf(c)))
	}
	keys := make([]string, len(s.key))
	for i, k := range s.key {
		keys[i] = fmt.Sprintf("quote_nullable(x.%s) || %s", QuoteIdent(k), quoteLiteral("::"+s.typeOf(k)))
	}
	keyExpr := "''"
	if len(keys) > 0 {
		keyExpr = "concat_ws(', ', " + strings.Join(keys, ", ") + ")"
	}
	rows, err := d.Pool.Query(ctx, fmt.Sprintf(`SELECT concat_ws(', ', %s), %s FROM %s x ORDER BY x::text`,
		strings.Join(values, ", "), keyExpr, t.Quoted()))
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	head := fmt.Sprintf("INSERT INTO %s AS t (%s) VALUES\n", t.Quoted(), identList(cols, ""))
	tail := s.conflict(in.Mode, cols) + ";\n"
	var count int64
	var batch int
	var kept []string
	for rows.Next() {
		var row, key string
		if err := rows.Scan(&row, &key); err != nil {
			return count, err
		}
		if batch == 0 {
			w.WriteString(head)
		} else {
			w.WriteString(",\n")
		}
		w.WriteString("(" + row + ")")
		batch++
		count++
		if in.Mode == ModeReplace {
			kept = append(kept, "("+key+")")
		}
		if batch == batchRows {
			w.WriteString("\n" + tail)
			batch = 0
		}
	}
	if err := rows.Err(); err != nil {
		return count, err
	}
	if batch > 0 {
		w.WriteString("\n" + tail)
	}
	if in.Mode == ModeReplace && len(kept) > 0 {
		fmt.Fprintf(w, "DELETE FROM %s AS t WHERE NOT EXISTS (SELECT 1 FROM (VALUES\n%s\n) AS k (%s) WHERE %s);\n",
			t.Quoted(), strings.Join(kept, ",\n"), identList(s.key, ""), s.join("k"))
	}
	return count, nil
}

func (s shape) typeOf(name string) string {
	for _, c := range s.columns {
		if c.Name == name {
			return c.Type
		}
	}
	return "text"
}

func (s shape) conflict(mode string, cols []string) string {
	if mode == ModeInsert {
		return ""
	}
	target := "ON CONFLICT (" + identList(s.key, "") + ")"
	set := setColumns(s, cols)
	if mode == ModeSkip || len(set) == 0 {
		return target + " DO NOTHING"
	}
	assign := make([]string, len(set))
	for i, c := range set {
		assign[i] = fmt.Sprintf("%s = excluded.%s", QuoteIdent(c), QuoteIdent(c))
	}
	when := differs(set, "t", "excluded")
	if mode == ModeLatest {
		when += " AND " + newer(s.updated, "t", "excluded")
	}
	return target + " DO UPDATE SET " + strings.Join(assign, ", ") + "\nWHERE " + when
}

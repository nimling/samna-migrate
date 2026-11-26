package data

import (
	"bufio"
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/sqlscan"
)

const (
	ModeInsert  = "insert"
	ModeCreate  = "create"
	ModeUpsert  = "upsert"
	ModeMerge   = "merge"
	ModeSkip    = "skip"
	ModeLatest  = "latest"
	ModeReplace = "replace"
)

var Modes = []string{ModeInsert, ModeCreate, ModeUpsert, ModeMerge, ModeSkip, ModeLatest, ModeReplace}

const (
	batchRows  = 1000
	batchBytes = 4 << 20
)

type Options struct {
	Mode       string
	Format     string
	UpdatedAt  string
	Plan       bool
	NoTriggers bool
	Progress   func(rows, bytes int64)
}

type Result struct {
	File       string   `json:"file"`
	Table      string   `json:"table"`
	Format     string   `json:"format"`
	Mode       string   `json:"mode,omitempty"`
	Plan       bool     `json:"plan"`
	Rows       int64    `json:"rows"`
	Inserted   int64    `json:"inserted"`
	Updated    int64    `json:"updated"`
	Skipped    int64    `json:"skipped"`
	Deleted    int64    `json:"deleted"`
	Refused    int64    `json:"refused"`
	Statements int      `json:"statements,omitempty"`
	Tables     []string `json:"tables,omitempty"`
	Ignored    []string `json:"ignored,omitempty"`
}

type column struct {
	Name      string
	Type      string
	Generated bool
}

type shape struct {
	table   Table
	columns []column
	key     []string
	updated string
}

func ValidMode(mode string) bool {
	for _, m := range Modes {
		if m == mode {
			return true
		}
	}
	return false
}

func InsertFile(ctx context.Context, d *db.DB, t Table, path string, in Options) (Result, error) {
	if in.Mode == "" {
		in.Mode = ModeInsert
	}
	format, ok := GetFormat(path)
	if !ok {
		return Result{}, fmt.Errorf("%s: no format is read from this extension, use one of %s", path, strings.Join(Formats, ", "))
	}
	out := Result{File: path, Table: t.Qualified(), Format: format, Mode: in.Mode, Plan: in.Plan}
	if format == FormatSQL {
		out.Mode = ""
		return insertSQL(ctx, d, t, path, in, out)
	}
	s, err := getShape(ctx, d, t, in)
	if err != nil {
		return out, fmt.Errorf("%s: %w", path, err)
	}

	f, err := os.Open(path)
	if err != nil {
		return out, err
	}
	defer f.Close()

	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	for _, set := range []string{"SET LOCAL statement_timeout = 0", "SET LOCAL client_min_messages = warning"} {
		if _, err := tx.Exec(ctx, set); err != nil {
			return out, err
		}
	}
	if in.NoTriggers && !in.Plan {
		if _, err := tx.Exec(ctx, fmt.Sprintf("ALTER TABLE %s DISABLE TRIGGER USER", t.Quoted())); err != nil {
			return out, err
		}
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(
		`CREATE TEMP TABLE smig_stage (n bigint NOT NULL, k text[] NOT NULL, r %s) ON COMMIT DROP`, t.Quoted())); err != nil {
		return out, err
	}

	if format == FormatCSV {
		out.Rows, err = stageCSV(ctx, tx, s, f, in.Progress)
	} else {
		out.Rows, err = stageJSON(ctx, tx, s, f, in.Progress)
	}
	if err != nil {
		return out, at(path, err)
	}
	if out.Rows == 0 {
		return out, nil
	}
	if _, err := tx.Exec(ctx, "ANALYZE smig_stage"); err != nil {
		return out, err
	}

	carried, ignored, err := s.carried(ctx, tx)
	if err != nil {
		return out, err
	}
	out.Ignored = ignored
	if err := s.check(ctx, tx, in.Mode); err != nil {
		return out, at(path, err)
	}

	if in.Plan {
		if err := s.plan(ctx, tx, in.Mode, carried, &out); err != nil {
			return out, at(path, err)
		}
		return out, nil
	}
	if err := s.refuse(ctx, tx, in.Mode, carried); err != nil {
		return out, at(path, err)
	}
	if err := s.write(ctx, tx, in.Mode, carried, &out); err != nil {
		return out, at(path, errors.New(pgMessage(err)))
	}
	if in.NoTriggers {
		if _, err := tx.Exec(ctx, fmt.Sprintf("ALTER TABLE %s ENABLE TRIGGER USER", t.Quoted())); err != nil {
			return out, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return out, err
	}
	return out, nil
}

func getShape(ctx context.Context, d *db.DB, t Table, in Options) (shape, error) {
	s := shape{table: t}
	cols, err := tableColumns(ctx, d, t)
	if err != nil {
		return s, err
	}
	s.columns = cols
	if len(s.insertable()) == 0 {
		return s, fmt.Errorf("%s has no insertable columns", t.Qualified())
	}
	s.key, err = primaryKey(ctx, d, t)
	if err != nil {
		return s, err
	}
	if in.Mode != ModeInsert && len(s.key) == 0 {
		return s, fmt.Errorf("%s has no primary key, so mode %s cannot match its rows; only mode insert loads it", t.Qualified(), in.Mode)
	}
	if in.Mode == ModeLatest {
		s.updated, err = s.updatedColumn(in.UpdatedAt)
		if err != nil {
			return s, err
		}
	}
	return s, nil
}

func (s shape) insertable() []string {
	out := []string{}
	for _, c := range s.columns {
		if !c.Generated {
			out = append(out, c.Name)
		}
	}
	return out
}

func (s shape) updatedColumn(named string) (string, error) {
	candidates := []string{named}
	if named == "" {
		candidates = []string{"sa_updated_at", "updated_at"}
	}
	for _, want := range candidates {
		for _, c := range s.columns {
			if c.Name == want {
				return c.Name, nil
			}
		}
	}
	if named != "" {
		return "", fmt.Errorf("%s has no column %s for mode latest to compare", s.table.Qualified(), named)
	}
	return "", fmt.Errorf("%s has no sa_updated_at or updated_at column for mode latest to compare, pass --updated-at=<column>", s.table.Qualified())
}

func (s shape) isKey(name string) bool {
	for _, k := range s.key {
		if k == name {
			return true
		}
	}
	return false
}

func (s shape) join(row string) string {
	parts := make([]string, len(s.key))
	for i, k := range s.key {
		parts[i] = fmt.Sprintf("t.%s = %s.%s", QuoteIdent(k), row, QuoteIdent(k))
	}
	return strings.Join(parts, " AND ")
}

func (s shape) keyText(row string) string {
	parts := make([]string, len(s.key))
	for i, k := range s.key {
		parts[i] = fmt.Sprintf("%s || '=' || COALESCE(%s.%s::text, 'null')", quoteLiteral(k), row, QuoteIdent(k))
	}
	return "concat_ws(', ', " + strings.Join(parts, ", ") + ")"
}

func setColumns(s shape, cols []string) []string {
	out := []string{}
	for _, c := range cols {
		if !s.isKey(c) {
			out = append(out, c)
		}
	}
	return out
}

func differs(cols []string, left, right string) string {
	if len(cols) == 0 {
		return "false"
	}
	l := make([]string, len(cols))
	r := make([]string, len(cols))
	for i, c := range cols {
		l[i] = fmt.Sprintf("to_jsonb(%s.%s)", left, QuoteIdent(c))
		r[i] = fmt.Sprintf("to_jsonb(%s.%s)", right, QuoteIdent(c))
	}
	return fmt.Sprintf("ROW(%s) IS DISTINCT FROM ROW(%s)", strings.Join(l, ", "), strings.Join(r, ", "))
}

func mergeDiffers(cols []string) string {
	if len(cols) == 0 {
		return "false"
	}
	parts := make([]string, len(cols))
	for i, c := range cols {
		parts[i] = fmt.Sprintf("(%s = ANY(s.k) AND to_jsonb(t.%s) IS DISTINCT FROM to_jsonb((s.r).%s))", quoteLiteral(c), QuoteIdent(c), QuoteIdent(c))
	}
	return "(" + strings.Join(parts, " OR ") + ")"
}

func newer(updated, left, right string) string {
	u := QuoteIdent(updated)
	return fmt.Sprintf("(%s.%s IS NOT NULL AND (%s.%s IS NULL OR %s.%s > %s.%s))", right, u, left, u, right, u, left, u)
}

func (s shape) updateWhen(mode string, carried []string) string {
	set := setColumns(s, carried)
	switch mode {
	case ModeUpsert, ModeReplace:
		return differs(set, "t", "(s.r)")
	case ModeMerge:
		return mergeDiffers(set)
	case ModeLatest:
		return differs(set, "t", "(s.r)") + " AND " + newer(s.updated, "t", "(s.r)")
	}
	return "false"
}

func (s shape) refuseWhen(mode string, carried []string) string {
	switch mode {
	case ModeInsert:
		return "true"
	case ModeCreate:
		return differs(setColumns(s, carried), "t", "(s.r)")
	}
	return "false"
}

func refusal(mode string) (string, string) {
	if mode == ModeInsert {
		return "exists", "Insert with --mode=upsert to update it, --mode=skip to leave it, or --mode=create to load only rows that are new or the same."
	}
	return "exists and differs", "Insert with --mode=upsert to update it, or --mode=skip to leave it."
}

func (s shape) carried(ctx context.Context, tx pgx.Tx) ([]string, []string, error) {
	rows, err := tx.Query(ctx, `SELECT DISTINCT unnest(k) FROM smig_stage`)
	if err != nil {
		return nil, nil, err
	}
	present := map[string]bool{}
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			rows.Close()
			return nil, nil, err
		}
		present[c] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	carried := []string{}
	known := map[string]bool{}
	for _, c := range s.columns {
		known[c.Name] = true
		if present[c.Name] && !c.Generated {
			carried = append(carried, c.Name)
		}
	}
	ignored := []string{}
	for c := range present {
		if !known[c] {
			ignored = append(ignored, c)
		}
	}
	sort.Strings(ignored)
	return carried, ignored, nil
}

func (s shape) check(ctx context.Context, tx pgx.Tx, mode string) error {
	if len(s.key) == 0 {
		return nil
	}
	nulls := make([]string, len(s.key))
	group := make([]string, len(s.key))
	for i, k := range s.key {
		nulls[i] = fmt.Sprintf("(s.r).%s IS NULL", QuoteIdent(k))
		group[i] = fmt.Sprintf("(s.r).%s", QuoteIdent(k))
	}
	if mode != ModeInsert {
		var line int64
		err := tx.QueryRow(ctx, fmt.Sprintf(`SELECT s.n FROM smig_stage s WHERE %s ORDER BY s.n LIMIT 1`, strings.Join(nulls, " OR "))).Scan(&line)
		switch {
		case err == nil:
			return fmt.Errorf("line %d: the row carries no %s, so mode %s cannot match it", line, strings.Join(s.key, ", "), mode)
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
	}
	var first, second int64
	var key string
	err := tx.QueryRow(ctx, fmt.Sprintf(`
		SELECT min(s.n), (array_agg(s.n ORDER BY s.n))[2], min(%s)
		FROM smig_stage s
		WHERE NOT (%s)
		GROUP BY %s
		HAVING count(*) > 1
		ORDER BY min(s.n)
		LIMIT 1`, s.keyText("(s.r)"), strings.Join(nulls, " OR "), strings.Join(group, ", "))).Scan(&first, &second, &key)
	switch {
	case err == nil:
		return fmt.Errorf("lines %d and %d: both rows carry the key %s", first, second, key)
	case errors.Is(err, pgx.ErrNoRows):
		return nil
	default:
		return err
	}
}

func at(path string, err error) error {
	if strings.HasPrefix(err.Error(), "line") {
		return fmt.Errorf("%s %w", path, err)
	}
	return fmt.Errorf("%s: %w", path, err)
}

func (s shape) plan(ctx context.Context, tx pgx.Tx, mode string, carried []string, out *Result) error {
	if len(s.key) == 0 {
		out.Inserted = out.Rows
		return nil
	}
	err := tx.QueryRow(ctx, fmt.Sprintf(`
		SELECT count(*) FILTER (WHERE t.ctid IS NULL),
		       count(*) FILTER (WHERE t.ctid IS NOT NULL AND %s),
		       count(*) FILTER (WHERE t.ctid IS NOT NULL AND %s)
		FROM smig_stage s LEFT JOIN %s t ON %s`,
		s.updateWhen(mode, carried), s.refuseWhen(mode, carried), s.table.Quoted(), s.join("(s.r)"))).
		Scan(&out.Inserted, &out.Updated, &out.Refused)
	if err != nil {
		return err
	}
	out.Skipped = out.Rows - out.Inserted - out.Updated - out.Refused
	if mode == ModeReplace && out.Rows > 0 {
		return tx.QueryRow(ctx, fmt.Sprintf(`
			SELECT count(*) FROM %s t WHERE NOT EXISTS (SELECT 1 FROM smig_stage s WHERE %s)`,
			s.table.Quoted(), s.join("(s.r)"))).Scan(&out.Deleted)
	}
	return nil
}

func (s shape) refuse(ctx context.Context, tx pgx.Tx, mode string, carried []string) error {
	if len(s.key) == 0 || (mode != ModeInsert && mode != ModeCreate) {
		return nil
	}
	var line, count int64
	var key string
	err := tx.QueryRow(ctx, fmt.Sprintf(`
		SELECT s.n, %s, count(*) OVER ()
		FROM smig_stage s JOIN %s t ON %s
		WHERE %s
		ORDER BY s.n
		LIMIT 1`, s.keyText("(s.r)"), s.table.Quoted(), s.join("(s.r)"), s.refuseWhen(mode, carried))).Scan(&line, &key, &count)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil
	case err != nil:
		return err
	}
	what, hint := refusal(mode)
	more := ""
	if count > 1 {
		more = fmt.Sprintf(", and %d more rows do too", count-1)
	}
	return &refused{message: fmt.Sprintf("line %d: %s %s %s in %s%s", line, strings.Join(s.key, ", "), key, what, s.table.Qualified(), more), hint: hint}
}

type refused struct {
	message string
	hint    string
}

func (r *refused) Error() string { return r.message }

func GetRefusal(err error) (string, string, bool) {
	var r *refused
	if errors.As(err, &r) {
		return err.Error(), r.hint, true
	}
	return "", "", false
}

func (s shape) write(ctx context.Context, tx pgx.Tx, mode string, carried []string, out *Result) error {
	if mode == ModeInsert {
		cols := s.insertable()
		tag, err := tx.Exec(ctx, fmt.Sprintf(`INSERT INTO %s (%s) SELECT %s FROM smig_stage s ORDER BY s.n`,
			s.table.Quoted(), identList(cols, ""), identList(cols, "(s.r).")))
		if err != nil {
			return err
		}
		out.Inserted = tag.RowsAffected()
		out.Skipped = out.Rows - out.Inserted
		return nil
	}
	if mode == ModeReplace && out.Rows > 0 {
		tag, err := tx.Exec(ctx, fmt.Sprintf(`DELETE FROM %s t WHERE NOT EXISTS (SELECT 1 FROM smig_stage s WHERE %s)`,
			s.table.Quoted(), s.join("(s.r)")))
		if err != nil {
			return err
		}
		out.Deleted = tag.RowsAffected()
	}
	set := setColumns(s, carried)
	if when := s.updateWhen(mode, carried); when != "false" && len(set) > 0 {
		assign := make([]string, len(set))
		for i, c := range set {
			q := QuoteIdent(c)
			if mode == ModeMerge {
				assign[i] = fmt.Sprintf("%s = CASE WHEN %s = ANY(s.k) THEN (s.r).%s ELSE t.%s END", q, quoteLiteral(c), q, q)
			} else {
				assign[i] = fmt.Sprintf("%s = (s.r).%s", q, q)
			}
		}
		tag, err := tx.Exec(ctx, fmt.Sprintf(`UPDATE %s t SET %s FROM smig_stage s WHERE %s AND %s`,
			s.table.Quoted(), strings.Join(assign, ", "), s.join("(s.r)"), when))
		if err != nil {
			return err
		}
		out.Updated = tag.RowsAffected()
	}
	tag, err := tx.Exec(ctx, fmt.Sprintf(`
		INSERT INTO %s (%s) SELECT %s FROM smig_stage s
		WHERE NOT EXISTS (SELECT 1 FROM %s t WHERE %s)
		ORDER BY s.n`,
		s.table.Quoted(), identList(carried, ""), identList(carried, "(s.r)."), s.table.Quoted(), s.join("(s.r)")))
	if err != nil {
		return err
	}
	out.Inserted = tag.RowsAffected()
	out.Skipped = out.Rows - out.Inserted - out.Updated
	return nil
}

func identList(cols []string, prefix string) string {
	out := make([]string, len(cols))
	for i, c := range cols {
		out[i] = prefix + QuoteIdent(c)
	}
	return strings.Join(out, ", ")
}

func quoteLiteral(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

func stageJSON(ctx context.Context, tx pgx.Tx, s shape, r io.Reader, progress func(rows, bytes int64)) (int64, error) {
	stage := fmt.Sprintf(`
		INSERT INTO smig_stage (n, k, r)
		SELECT l.n, ARRAY(SELECT jsonb_object_keys(e.j)), jsonb_populate_record(NULL::%s, e.j)
		FROM jsonb_array_elements($1::jsonb) WITH ORDINALITY e(j, i)
		JOIN unnest($2::bigint[]) WITH ORDINALITY l(n, i) USING (i)`, s.table.Quoted())
	var total, read int64
	var body bytes.Buffer
	lines := make([]int64, 0, batchRows)
	rows := make([][]byte, 0, batchRows)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		body.Reset()
		body.WriteByte('[')
		for i, row := range rows {
			if i > 0 {
				body.WriteByte(',')
			}
			body.Write(row)
		}
		body.WriteByte(']')
		if err := stageBatch(ctx, tx, stage, body.String(), lines, rows); err != nil {
			return err
		}
		total += int64(len(rows))
		rows = rows[:0]
		lines = lines[:0]
		if progress != nil {
			progress(total, read)
		}
		return nil
	}
	var size int
	err := readRows(r, func(line int64, row []byte, offset int64) error {
		if len(row) == 0 || row[0] != '{' {
			return fmt.Errorf("line %d: the row is not a json object", line)
		}
		rows = append(rows, row)
		lines = append(lines, line)
		size += len(row)
		read = offset
		if len(rows) >= batchRows || size >= batchBytes {
			size = 0
			return flush()
		}
		return nil
	})
	if err != nil {
		return total, err
	}
	return total, flush()
}

func stageBatch(ctx context.Context, tx pgx.Tx, stage, body string, lines []int64, rows [][]byte) error {
	if _, err := tx.Exec(ctx, "SAVEPOINT smig_batch"); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, stage, body, lines)
	if err == nil {
		_, err = tx.Exec(ctx, "RELEASE SAVEPOINT smig_batch")
		return err
	}
	if _, rerr := tx.Exec(ctx, "ROLLBACK TO SAVEPOINT smig_batch"); rerr != nil {
		return err
	}
	for i, row := range rows {
		if _, serr := tx.Exec(ctx, stage, "["+string(row)+"]", []int64{lines[i]}); serr != nil {
			return fmt.Errorf("line %d: %s", lines[i], pgMessage(serr))
		}
	}
	return fmt.Errorf("lines %d to %d: %s", lines[0], lines[len(lines)-1], pgMessage(err))
}

func readRows(r io.Reader, each func(line int64, row []byte, offset int64) error) error {
	counted := &lineCounter{r: r}
	br := bufio.NewReaderSize(counted, 1<<20)
	first, lead, err := firstByte(br)
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return err
	}
	if first == '[' {
		dec := json.NewDecoder(br)
		if _, err := dec.Token(); err != nil {
			return fmt.Errorf("line 1: %w", err)
		}
		for dec.More() {
			var raw json.RawMessage
			if err := dec.Decode(&raw); err != nil {
				return fmt.Errorf("line %d: %w", counted.line(lead+dec.InputOffset()), err)
			}
			end := lead + dec.InputOffset()
			if err := each(counted.line(end-int64(len(raw))), raw, end); err != nil {
				return err
			}
		}
		if _, err := dec.Token(); err != nil {
			return fmt.Errorf("line %d: the json array does not close: %w", counted.line(lead+dec.InputOffset()), err)
		}
		return nil
	}
	var line, offset int64
	for {
		raw, err := br.ReadBytes('\n')
		offset += int64(len(raw))
		if len(raw) > 0 {
			line++
			if row := bytes.TrimSpace(raw); len(row) > 0 {
				if err := each(line, row, offset); err != nil {
					return err
				}
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func firstByte(br *bufio.Reader) (byte, int64, error) {
	var lead int64
	for {
		b, err := br.Peek(1)
		if err != nil {
			return 0, lead, err
		}
		switch b[0] {
		case ' ', '\t', '\r', '\n':
			if _, err := br.Discard(1); err != nil {
				return 0, lead, err
			}
			lead++
		default:
			return b[0], lead, nil
		}
	}
}

type lineCounter struct {
	r    io.Reader
	off  int64
	base int64
	nl   []int64
}

func (c *lineCounter) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	for i := 0; i < n; i++ {
		if p[i] == '\n' {
			c.nl = append(c.nl, c.off+int64(i))
		}
	}
	c.off += int64(n)
	return n, err
}

func (c *lineCounter) line(offset int64) int64 {
	i := sort.Search(len(c.nl), func(i int) bool { return c.nl[i] >= offset })
	line := c.base + int64(i) + 1
	c.nl = c.nl[i:]
	c.base += int64(i)
	return line
}

var rxCopyLine = regexp.MustCompile(`line (\d+)`)

func stageCSV(ctx context.Context, tx pgx.Tx, s shape, r io.Reader, progress func(rows, bytes int64)) (int64, error) {
	br := bufio.NewReaderSize(r, 1<<20)
	head, err := br.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return 0, err
	}
	if strings.TrimSpace(head) == "" {
		return 0, nil
	}
	header, err := csv.NewReader(strings.NewReader(head)).Read()
	if err != nil {
		return 0, fmt.Errorf("line 1: the header is not csv: %w", err)
	}
	types := map[string]string{}
	for _, c := range s.columns {
		types[c.Name] = c.Type
	}
	defs := make([]string, len(header))
	for i, name := range header {
		typ, ok := types[name]
		if !ok {
			return 0, fmt.Errorf("line 1: column %s is not in %s", name, s.table.Qualified())
		}
		defs[i] = QuoteIdent(name) + " " + typ
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(`CREATE TEMP TABLE smig_csv (%s) ON COMMIT DROP`, strings.Join(defs, ", "))); err != nil {
		return 0, err
	}
	counted := &byteCounter{r: br, off: int64(len(head)), progress: progress}
	if _, err := tx.Conn().PgConn().CopyFrom(ctx, counted, fmt.Sprintf(`COPY smig_csv (%s) FROM STDIN (FORMAT csv)`, identList(header, ""))); err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) {
			if m := rxCopyLine.FindStringSubmatch(pg.Where); m != nil {
				n, _ := strconv.ParseInt(m[1], 10, 64)
				return 0, fmt.Errorf("line %d: %s", n+1, pgMessage(err))
			}
		}
		return 0, errors.New(pgMessage(err))
	}
	tag, err := tx.Exec(ctx, fmt.Sprintf(`
		INSERT INTO smig_stage (n, k, r)
		SELECT row_number() OVER () + 1, $1::text[], jsonb_populate_record(NULL::%s, to_jsonb(c))
		FROM smig_csv c`, s.table.Quoted()), header)
	if err != nil {
		return 0, errors.New(pgMessage(err))
	}
	if progress != nil {
		progress(tag.RowsAffected(), counted.off)
	}
	return tag.RowsAffected(), nil
}

type byteCounter struct {
	r        io.Reader
	off      int64
	progress func(rows, bytes int64)
}

func (c *byteCounter) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.off += int64(n)
	if c.progress != nil && n > 0 {
		c.progress(-1, c.off)
	}
	return n, err
}

func pgMessage(err error) string {
	var pg *pgconn.PgError
	if !errors.As(err, &pg) {
		return err.Error()
	}
	msg := pg.Message
	if pg.Detail != "" {
		msg += ", " + pg.Detail
	}
	return msg
}

var rxStatementTarget = regexp.MustCompile(`(?is)^(?:insert\s+into|update(?:\s+only)?|delete\s+from(?:\s+only)?|truncate(?:\s+table)?(?:\s+only)?|merge\s+into)\s+("(?:[^"]|"")+"|[a-z_][a-z0-9_$]*)(?:\s*\.\s*("(?:[^"]|"")+"|[a-z_][a-z0-9_$]*))?`)

func statementTarget(stmt string) string {
	m := rxStatementTarget.FindStringSubmatch(stmt)
	if m == nil {
		return ""
	}
	ident := func(p string) string {
		if strings.HasPrefix(p, `"`) {
			return strings.ReplaceAll(p[1:len(p)-1], `""`, `"`)
		}
		return strings.ToLower(p)
	}
	if m[2] == "" {
		return ident(m[1])
	}
	return ident(m[1]) + "." + ident(m[2])
}

func insertSQL(ctx context.Context, d *db.DB, t Table, path string, in Options, out Result) (Result, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return out, err
	}
	body := string(raw)
	type statement struct {
		text string
		line int64
	}
	stmts := []statement{}
	touched := map[string]bool{}
	line := int64(1)
	for i := 0; i < len(body); {
		j := sqlscan.SkipTrivia(body, i)
		if j >= len(body) {
			break
		}
		line += int64(strings.Count(body[i:j], "\n"))
		end := sqlscan.StatementEnd(body, j)
		text := body[j:end]
		stmts = append(stmts, statement{text: text, line: line})
		if target := statementTarget(text); target != "" {
			touched[target] = true
		}
		line += int64(strings.Count(text, "\n"))
		i = end
	}
	out.Statements = len(stmts)
	for target := range touched {
		out.Tables = append(out.Tables, target)
	}
	sort.Strings(out.Tables)
	if in.Plan {
		return out, nil
	}

	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	for _, set := range []string{"SET LOCAL statement_timeout = 0", "SET LOCAL client_min_messages = warning"} {
		if _, err := tx.Exec(ctx, set); err != nil {
			return out, err
		}
	}
	if in.NoTriggers {
		if _, err := tx.Exec(ctx, fmt.Sprintf("ALTER TABLE %s DISABLE TRIGGER USER", t.Quoted())); err != nil {
			return out, err
		}
	}
	for i, st := range stmts {
		tag, err := tx.Exec(ctx, st.text)
		if err != nil {
			return out, fmt.Errorf("%s line %d: %s", path, st.line, pgMessage(err))
		}
		out.Rows += tag.RowsAffected()
		if in.Progress != nil {
			in.Progress(int64(i+1), 0)
		}
	}
	if in.NoTriggers {
		if _, err := tx.Exec(ctx, fmt.Sprintf("ALTER TABLE %s ENABLE TRIGGER USER", t.Quoted())); err != nil {
			return out, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return out, err
	}
	return out, nil
}

func tableColumns(ctx context.Context, d *db.DB, t Table) ([]column, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attgenerated <> ''
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2
		  AND a.attnum > 0 AND NOT a.attisdropped
		ORDER BY a.attnum`, t.Schema, t.Name)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []column{}
	for rows.Next() {
		var c column
		if err := rows.Scan(&c.Name, &c.Type, &c.Generated); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func primaryKey(ctx context.Context, d *db.DB, t Table) ([]string, error) {
	rows, err := d.Pool.Query(ctx, `
		SELECT a.attname
		FROM pg_index i
		JOIN pg_class c ON c.oid = i.indrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
		WHERE n.nspname = $1 AND c.relname = $2 AND i.indisprimary
		ORDER BY array_position(i.indkey::int2[], a.attnum)`, t.Schema, t.Name)
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

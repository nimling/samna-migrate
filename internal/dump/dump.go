package dump

import (
	"context"
	"fmt"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
)

// LiveDefinition returns idempotent SQL that recreates the named object as it
// exists in the live database. An empty string means the object is absent.
// schemas scopes name only lookups for triggers and indexes to the owning
// step's schemas, so dynamically attached twins on other schemas stay out.
func LiveDefinition(ctx context.Context, d *db.DB, kind, ident string, schemas []string) (string, error) {
	schema, name := splitIdent(ident)
	switch strings.ToUpper(kind) {
	case "FUNCTION", "PROCEDURE":
		return functionDef(ctx, d, schema, name)
	case "TRIGGER":
		return triggerDef(ctx, d, schema, name, schemas)
	case "INDEX":
		return indexDef(ctx, d, schema, name, schemas)
	case "VIEW":
		return viewDef(ctx, d, schema, name)
	case "TYPE":
		return typeDef(ctx, d, schema, name)
	case "TABLE":
		return tableDef(ctx, d, schema, name)
	case "SEQUENCE":
		return sequenceDef(ctx, d, schema, name)
	}
	return "", fmt.Errorf("unsupported object kind %s", kind)
}

func splitIdent(ident string) (string, string) {
	if i := strings.LastIndex(ident, "."); i >= 0 {
		return ident[:i], ident[i+1:]
	}
	return "", ident
}

func collect(ctx context.Context, d *db.DB, query string, args ...any) ([]string, error) {
	rows, err := d.Pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func functionDef(ctx context.Context, d *db.DB, schema, name string) (string, error) {
	defs, err := collect(ctx, d, `
		SELECT pg_get_functiondef(p.oid) || ';'
		FROM pg_proc p
		JOIN pg_namespace n ON n.oid = p.pronamespace
		WHERE p.proname = $1 AND ($2 = '' OR n.nspname = $2) AND p.prokind IN ('f', 'p')
		ORDER BY pg_get_function_identity_arguments(p.oid)`, name, schema)
	if err != nil {
		return "", err
	}
	if len(defs) == 0 {
		return "", nil
	}
	grants, err := collect(ctx, d, `
		SELECT 'GRANT EXECUTE ON FUNCTION ' || n.nspname || '.' || p.proname
		       || '(' || pg_get_function_identity_arguments(p.oid) || ') TO '
		       || CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(acl.grantee)) END || ';'
		FROM pg_proc p
		JOIN pg_namespace n ON n.oid = p.pronamespace,
		LATERAL aclexplode(p.proacl) acl
		WHERE p.proname = $1 AND ($2 = '' OR n.nspname = $2) AND p.prokind IN ('f', 'p')
		  AND acl.grantee <> p.proowner AND acl.privilege_type = 'EXECUTE'
		ORDER BY 1`, name, schema)
	if err != nil {
		return "", err
	}
	comments, err := collect(ctx, d, `
		SELECT 'COMMENT ON FUNCTION ' || n.nspname || '.' || p.proname
		       || '(' || pg_get_function_identity_arguments(p.oid) || ') IS '
		       || quote_literal(de.description) || ';'
		FROM pg_description de
		JOIN pg_proc p ON de.classoid = 'pg_proc'::regclass AND de.objoid = p.oid
		JOIN pg_namespace n ON n.oid = p.pronamespace
		WHERE p.proname = $1 AND ($2 = '' OR n.nspname = $2)
		ORDER BY 1`, name, schema)
	if err != nil {
		return "", err
	}
	out := strings.Join(defs, "\n\n")
	if len(grants) > 0 {
		out += "\n\n" + strings.Join(grants, "\n")
	}
	if len(comments) > 0 {
		out += "\n\n" + strings.Join(comments, "\n")
	}
	return out, nil
}

func triggerDef(ctx context.Context, d *db.DB, schema, name string, schemas []string) (string, error) {
	defs, err := collect(ctx, d, `
		SELECT 'DROP TRIGGER IF EXISTS ' || quote_ident(t.tgname) || ' ON '
		       || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || E';\n'
		       || pg_get_triggerdef(t.oid) || ';'
		FROM pg_trigger t
		JOIN pg_class c ON c.oid = t.tgrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE NOT t.tgisinternal AND t.tgname = $1 AND ($2 = '' OR n.nspname = $2)
		  AND ($3::text[] IS NULL OR n.nspname = ANY($3))
		ORDER BY n.nspname, c.relname`, name, schema, schemas)
	if err != nil {
		return "", err
	}
	return strings.Join(defs, "\n\n"), nil
}

func indexDef(ctx context.Context, d *db.DB, schema, name string, schemas []string) (string, error) {
	defs, err := collect(ctx, d, `
		SELECT indexdef || ';'
		FROM pg_indexes
		WHERE indexname = $1 AND ($2 = '' OR schemaname = $2)
		  AND ($3::text[] IS NULL OR schemaname = ANY($3))
		ORDER BY schemaname`, name, schema, schemas)
	if err != nil {
		return "", err
	}
	for i, def := range defs {
		defs[i] = injectIndexGuard(def)
	}
	return strings.Join(defs, "\n\n"), nil
}

func injectIndexGuard(def string) string {
	if strings.Contains(strings.ToUpper(def), "IF NOT EXISTS") {
		return def
	}
	upper := strings.ToUpper(def)
	for _, head := range []string{"CREATE UNIQUE INDEX ", "CREATE INDEX "} {
		if strings.HasPrefix(upper, head) {
			return def[:len(head)] + "IF NOT EXISTS " + def[len(head):]
		}
	}
	return def
}

func viewDef(ctx context.Context, d *db.DB, schema, name string) (string, error) {
	defs, err := collect(ctx, d, `
		SELECT 'CREATE OR REPLACE VIEW ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
		       || ' AS ' || pg_get_viewdef(c.oid, true)
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind = 'v' AND c.relname = $1 AND ($2 = '' OR n.nspname = $2)
		ORDER BY n.nspname`, name, schema)
	if err != nil {
		return "", err
	}
	for i, def := range defs {
		if !strings.HasSuffix(strings.TrimSpace(def), ";") {
			defs[i] = strings.TrimSpace(def) + ";"
		}
	}
	return strings.Join(defs, "\n\n"), nil
}

func typeDef(ctx context.Context, d *db.DB, schema, name string) (string, error) {
	enums, err := collect(ctx, d, `
		SELECT 'CREATE TYPE ' || quote_ident(n.nspname) || '.' || quote_ident(t.typname)
		       || ' AS ENUM (' || string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder) || ');'
		FROM pg_type t
		JOIN pg_namespace n ON n.oid = t.typnamespace
		JOIN pg_enum e ON e.enumtypid = t.oid
		WHERE t.typname = $1 AND ($2 = '' OR n.nspname = $2)
		GROUP BY n.nspname, t.typname`, name, schema)
	if err != nil {
		return "", err
	}
	composites, err := collect(ctx, d, `
		SELECT 'CREATE TYPE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
		       || ' AS (' || string_agg(quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum) || ');'
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
		WHERE c.relkind = 'c' AND c.relname = $1 AND ($2 = '' OR n.nspname = $2)
		GROUP BY n.nspname, c.relname`, name, schema)
	if err != nil {
		return "", err
	}
	defs := append(enums, composites...)
	for i, def := range defs {
		defs[i] = guardType(name, def)
	}
	return strings.Join(defs, "\n\n"), nil
}

func guardType(name, create string) string {
	return "DO $$\nBEGIN\n    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = '" + name + "') THEN\n        " +
		strings.TrimSuffix(create, ";") + ";\n    END IF;\nEND $$;"
}

// DeferredDefaults returns ALTER TABLE SET DEFAULT statements for the table's
// columns whose default calls a schema qualified function. These apply after
// the table and its function both exist, sidestepping the case where a table
// sits before its default's function in apply order.
func DeferredDefaults(ctx context.Context, d *db.DB, ident string) ([]string, error) {
	schema, name := splitIdent(ident)
	return collect(ctx, d, `
		SELECT 'ALTER TABLE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
		       || ' ALTER COLUMN ' || quote_ident(a.attname)
		       || ' SET DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid) || ';'
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
		JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
		WHERE c.relkind = 'r' AND c.relname = $1 AND ($2 = '' OR n.nspname = $2)
		  AND pg_get_expr(ad.adbin, ad.adrelid) ~ $3
		ORDER BY a.attnum`, name, schema, qualifiedDefaultRx)
}

// qualifiedDefaultRx matches a default expression that calls a schema
// qualified function, like claimius.get_disciple_app_id(). Those functions are
// dumped objects that may be defined after the table in apply order, so the
// default is deferred to an ALTER applied once every function exists. Builtins
// like now() and gen_random_uuid() are unqualified and stay inline.
const qualifiedDefaultRx = `[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*\(`

func tableDef(ctx context.Context, d *db.DB, schema, name string) (string, error) {
	cols, err := collect(ctx, d, `
		SELECT quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod)
		       || CASE WHEN ad.adbin IS NOT NULL AND pg_get_expr(ad.adbin, ad.adrelid) !~ $3
		               THEN ' DEFAULT ' || pg_get_expr(ad.adbin, ad.adrelid) ELSE '' END
		       || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
		LEFT JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
		WHERE c.relkind = 'r' AND c.relname = $1 AND ($2 = '' OR n.nspname = $2)
		ORDER BY a.attnum`, name, schema, qualifiedDefaultRx)
	if err != nil {
		return "", err
	}
	if len(cols) == 0 {
		return "", nil
	}
	cons, err := collect(ctx, d, `
		SELECT 'CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid)
		FROM pg_constraint con
		JOIN pg_class c ON c.oid = con.conrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relname = $1 AND ($2 = '' OR n.nspname = $2)
		ORDER BY con.conname`, name, schema)
	if err != nil {
		return "", err
	}
	qualified := name
	if schema != "" {
		qualified = schema + "." + name
	}
	lines := append(cols, cons...)
	return "CREATE TABLE IF NOT EXISTS " + qualified + " (\n    " + strings.Join(lines, ",\n    ") + "\n);", nil
}

func sequenceDef(ctx context.Context, d *db.DB, schema, name string) (string, error) {
	defs, err := collect(ctx, d, `
		SELECT 'CREATE SEQUENCE IF NOT EXISTS ' || quote_ident(schemaname) || '.' || quote_ident(sequencename)
		       || ' AS ' || data_type::text
		       || ' START ' || start_value
		       || ' INCREMENT ' || increment_by || ';'
		FROM pg_sequences
		WHERE sequencename = $1 AND ($2 = '' OR schemaname = $2)
		ORDER BY schemaname`, name, schema)
	if err != nil {
		return "", err
	}
	return strings.Join(defs, "\n\n"), nil
}

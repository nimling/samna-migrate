package dump

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/nimling/samna-migrate/internal/config"
	"github.com/nimling/samna-migrate/internal/db"
)

type SourceFlags struct {
	UsesGrant       bool
	UsesComment     bool
	UsesPolicy      bool
	UsesExtension   bool
	UsesDefaultPriv bool
	UsesSeqOwned    bool
}

var (
	rxGrant      = regexp.MustCompile(`(?i)GRANT|REVOKE`)
	rxComment    = regexp.MustCompile(`(?i)COMMENT\s+ON`)
	rxPolicy     = regexp.MustCompile(`(?i)CREATE\s+POLICY|ROW\s+LEVEL\s+SECURITY`)
	rxExtension  = regexp.MustCompile(`(?i)CREATE\s+EXTENSION`)
	rxDefaultPri = regexp.MustCompile(`(?i)ALTER\s+DEFAULT\s+PRIVILEGES`)
	rxSeqOwned   = regexp.MustCompile(`(?i)ALTER\s+SEQUENCE\s+.*OWNED\s+BY`)
)

// DetectSourceUses scans files for which DDL families they touch.
func DetectSourceUses(files []string) (*SourceFlags, error) {
	f := &SourceFlags{}
	for _, p := range files {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		if rxGrant.Match(b) {
			f.UsesGrant = true
		}
		if rxComment.Match(b) {
			f.UsesComment = true
		}
		if rxPolicy.Match(b) {
			f.UsesPolicy = true
		}
		if rxExtension.Match(b) {
			f.UsesExtension = true
		}
		if rxDefaultPri.Match(b) {
			f.UsesDefaultPriv = true
		}
		if rxSeqOwned.Match(b) {
			f.UsesSeqOwned = true
		}
	}
	return f, nil
}

// ObjectsForSchemas dumps schema-scoped objects to the given writer.
// Mirrors dump_objects_for_schemas in migrate.sh: enums, tables, indexes, views, optionally grants/comments/policies/etc.
func ObjectsForSchemas(ctx context.Context, d *db.DB, cfg *config.Config, schemas []string, flags *SourceFlags) (string, error) {
	if len(schemas) == 0 {
		return "", nil
	}
	var out bytes.Buffer

	quoted := quoteIdentsCSV(schemas)

	if flags.UsesExtension {
		rows, err := d.Pool.Query(ctx, fmt.Sprintf(`
			SELECT 'CREATE EXTENSION IF NOT EXISTS '||quote_ident(extname)||' WITH SCHEMA '||quote_ident(n.nspname)||';'
			FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
			WHERE n.nspname IN (%s) ORDER BY extname`, quoted))
		if err != nil {
			return "", err
		}
		for rows.Next() {
			var s string
			rows.Scan(&s)
			out.WriteString(s + "\n")
		}
		rows.Close()
		out.WriteString("\n")
	}

	// enums
	rows, err := d.Pool.Query(ctx, fmt.Sprintf(`
		SELECT 'CREATE TYPE '||quote_ident(n.nspname)||'.'||quote_ident(t.typname)||
		       ' AS ENUM ('||string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder)||');'
		FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
		JOIN pg_enum e ON e.enumtypid = t.oid
		WHERE n.nspname IN (%s)
		GROUP BY n.nspname, t.typname
		ORDER BY n.nspname, t.typname`, quoted))
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var s string
		rows.Scan(&s)
		out.WriteString(s + "\n")
	}
	rows.Close()
	out.WriteString("\n")

	// tables via pg_dump --schema-only
	args := []string{"--schema-only", "--no-owner", "--no-comments", "--no-publications", "--no-subscriptions"}
	if cfg.PGHost != "" {
		args = append(args, "--host", cfg.PGHost)
	}
	if cfg.PGPort != "" {
		args = append(args, "--port", cfg.PGPort)
	}
	args = append(args, "--username", cfg.PGUser, "--dbname", cfg.PGDatabase)
	for _, s := range schemas {
		args = append(args, "--schema="+s)
	}
	cmd := exec.CommandContext(ctx, "pg_dump", args...)
	cmd.Env = append(os.Environ(), "PGPASSWORD="+cfg.PGPassword)
	dump, err := cmd.Output()
	if err == nil {
		// Filter to CREATE TABLE blocks
		var inTable bool
		for _, line := range strings.Split(string(dump), "\n") {
			trim := strings.TrimSpace(line)
			if strings.HasPrefix(trim, "CREATE TABLE ") {
				inTable = true
			}
			if inTable {
				out.WriteString(line + "\n")
				if strings.HasSuffix(trim, ";") {
					inTable = false
				}
			}
		}
		out.WriteString("\n")
	}

	// indexes
	rows, err = d.Pool.Query(ctx, fmt.Sprintf(`
		SELECT indexdef||';' FROM pg_indexes WHERE schemaname IN (%s) ORDER BY schemaname, indexname`, quoted))
	if err == nil {
		for rows.Next() {
			var s string
			rows.Scan(&s)
			out.WriteString(s + "\n")
		}
		rows.Close()
		out.WriteString("\n")
	}

	// views
	rows, err = d.Pool.Query(ctx, fmt.Sprintf(`
		SELECT 'CREATE OR REPLACE VIEW '||quote_ident(n.nspname)||'.'||quote_ident(c.relname)||
		       ' AS '||pg_get_viewdef(c.oid, true)
		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind IN ('v','m') AND n.nspname IN (%s)
		ORDER BY n.nspname, c.relname`, quoted))
	if err == nil {
		for rows.Next() {
			var s string
			rows.Scan(&s)
			out.WriteString(s + "\n")
		}
		rows.Close()
	}

	return out.String(), nil
}

func quoteIdentsCSV(s []string) string {
	out := make([]string, 0, len(s))
	for _, v := range s {
		out = append(out, "'"+strings.ReplaceAll(v, "'", "''")+"'")
	}
	return strings.Join(out, ", ")
}

package reconcile

import (
	"context"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
)

var inventoryQueries = []string{
	`SELECT 'extension ' || e.extname, n.nspname
	 FROM pg_extension e
	 JOIN pg_namespace n ON n.oid = e.extnamespace
	 WHERE n.nspname = ANY($1)`,

	`SELECT 'enum ' || n.nspname || '.' || t.typname,
	        string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder)
	 FROM pg_type t
	 JOIN pg_namespace n ON n.oid = t.typnamespace
	 JOIN pg_enum e ON e.enumtypid = t.oid
	 WHERE n.nspname = ANY($1)
	 GROUP BY n.nspname, t.typname`,

	`SELECT 'type ' || n.nspname || '.' || c.relname,
	        string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod), ',' ORDER BY a.attnum)
	 FROM pg_class c
	 JOIN pg_namespace n ON n.oid = c.relnamespace
	 JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
	 WHERE c.relkind = 'c' AND n.nspname = ANY($1)
	 GROUP BY n.nspname, c.relname`,

	`SELECT 'table ' || n.nspname || '.' || c.relname,
	        string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
	            || CASE WHEN a.attnotnull THEN ' not null' ELSE '' END
	            || CASE WHEN d.adbin IS NOT NULL THEN ' default ' || pg_get_expr(d.adbin, d.adrelid) ELSE '' END,
	            E'\n' ORDER BY a.attnum)
	 FROM pg_class c
	 JOIN pg_namespace n ON n.oid = c.relnamespace
	 JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
	 LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
	 WHERE c.relkind = 'r' AND n.nspname = ANY($1)
	 GROUP BY n.nspname, c.relname`,

	`SELECT 'constraint ' || n.nspname || '.' || c.relname || '.' || con.conname,
	        pg_get_constraintdef(con.oid)
	 FROM pg_constraint con
	 JOIN pg_class c ON c.oid = con.conrelid
	 JOIN pg_namespace n ON n.oid = c.relnamespace
	 WHERE n.nspname = ANY($1)`,

	`SELECT 'index ' || schemaname || '.' || indexname, indexdef
	 FROM pg_indexes
	 WHERE schemaname = ANY($1)`,

	`SELECT 'view ' || n.nspname || '.' || c.relname, pg_get_viewdef(c.oid, true)
	 FROM pg_class c
	 JOIN pg_namespace n ON n.oid = c.relnamespace
	 WHERE c.relkind IN ('v', 'm') AND n.nspname = ANY($1)`,

	`SELECT 'function ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
	        pg_get_functiondef(p.oid)
	 FROM pg_proc p
	 JOIN pg_namespace n ON n.oid = p.pronamespace
	 WHERE n.nspname = ANY($1) AND p.prokind IN ('f', 'p')`,

	`SELECT 'trigger ' || n.nspname || '.' || c.relname || '.' || t.tgname,
	        pg_get_triggerdef(t.oid)
	 FROM pg_trigger t
	 JOIN pg_class c ON c.oid = t.tgrelid
	 JOIN pg_namespace n ON n.oid = c.relnamespace
	 WHERE NOT t.tgisinternal AND n.nspname = ANY($1)`,

	`SELECT 'sequence ' || schemaname || '.' || sequencename,
	        data_type::text || ' start ' || start_value || ' increment ' || increment_by
	 FROM pg_sequences
	 WHERE schemaname = ANY($1)`,

	`SELECT 'grant ' || n.nspname || '.' || c.relname || ' '
	        || CASE WHEN acl.grantee = 0 THEN 'public' ELSE pg_get_userbyid(acl.grantee) END,
	        string_agg(acl.privilege_type, ',' ORDER BY acl.privilege_type)
	 FROM pg_class c
	 JOIN pg_namespace n ON n.oid = c.relnamespace,
	 LATERAL aclexplode(c.relacl) acl
	 WHERE n.nspname = ANY($1) AND c.relkind IN ('r', 'v', 'm', 'S') AND acl.grantee <> c.relowner
	 GROUP BY n.nspname, c.relname, acl.grantee`,

	`SELECT 'grant function ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ') '
	        || CASE WHEN acl.grantee = 0 THEN 'public' ELSE pg_get_userbyid(acl.grantee) END,
	        string_agg(acl.privilege_type, ',' ORDER BY acl.privilege_type)
	 FROM pg_proc p
	 JOIN pg_namespace n ON n.oid = p.pronamespace,
	 LATERAL aclexplode(p.proacl) acl
	 WHERE n.nspname = ANY($1) AND acl.grantee <> p.proowner
	 GROUP BY n.nspname, p.proname, p.oid, acl.grantee`,

	`SELECT 'comment function ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
	        d.description
	 FROM pg_description d
	 JOIN pg_proc p ON d.classoid = 'pg_proc'::regclass AND d.objoid = p.oid
	 JOIN pg_namespace n ON n.oid = p.pronamespace
	 WHERE n.nspname = ANY($1)`,

	`SELECT 'comment type ' || n.nspname || '.' || t.typname, d.description
	 FROM pg_description d
	 JOIN pg_type t ON d.classoid = 'pg_type'::regclass AND d.objoid = t.oid
	 JOIN pg_namespace n ON n.oid = t.typnamespace
	 WHERE n.nspname = ANY($1)`,

	`SELECT 'comment table ' || n.nspname || '.' || c.relname
	        || CASE WHEN d.objsubid > 0 THEN '.' || a.attname ELSE '' END,
	        d.description
	 FROM pg_description d
	 JOIN pg_class c ON d.classoid = 'pg_class'::regclass AND d.objoid = c.oid
	 JOIN pg_namespace n ON n.oid = c.relnamespace
	 LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.objsubid
	 WHERE n.nspname = ANY($1)`,
}

func Inventory(ctx context.Context, d *db.DB, schemas []string) (map[string]string, error) {
	out := map[string]string{}
	for _, q := range inventoryQueries {
		rows, err := d.Pool.Query(ctx, q, schemas)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var identity, def string
			if err := rows.Scan(&identity, &def); err != nil {
				rows.Close()
				return nil, err
			}
			out[identity] = def
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	return out, nil
}

type InventoryDiff struct {
	Missing   []string
	Extra     []string
	Different []string
}

func (d *InventoryDiff) Empty() bool {
	return len(d.Missing) == 0 && len(d.Extra) == 0 && len(d.Different) == 0
}

func CompareInventories(want, got map[string]string) *InventoryDiff {
	diff := &InventoryDiff{}
	for k, v := range want {
		gv, ok := got[k]
		if !ok {
			diff.Missing = append(diff.Missing, k)
			continue
		}
		if gv != v {
			diff.Different = append(diff.Different, k)
		}
	}
	for k := range got {
		if _, ok := want[k]; !ok {
			diff.Extra = append(diff.Extra, k)
		}
	}
	sort.Strings(diff.Missing)
	sort.Strings(diff.Extra)
	sort.Strings(diff.Different)
	return diff
}

func reportDiff(diff *InventoryDiff, live, candidate map[string]string) {
	group := func(label string, items []string, line func(string, ...any)) {
		if len(items) == 0 {
			return
		}
		log.Info("%s: %d", label, len(items))
		for _, it := range items {
			line("  %s", it)
		}
	}
	group("in live, not produced by the files", diff.Missing, log.Warn)
	group("produced by the files, not in live", diff.Extra, log.Success)

	if len(diff.Different) > 0 {
		log.Info("definition differs: %d", len(diff.Different))
		for _, it := range diff.Different {
			log.Warn("  %s", it)
			if log.Level >= log.LevelVerbose {
				onlyLive, onlyCand := lineDelta(live[it], candidate[it])
				for _, ln := range onlyLive {
					log.DiffLine('-', ln)
				}
				for _, ln := range onlyCand {
					log.DiffLine('+', ln)
				}
			}
		}
	}
}

func lineDelta(a, b string) (onlyA, onlyB []string) {
	inB := map[string]bool{}
	for _, ln := range strings.Split(b, "\n") {
		inB[strings.TrimRight(ln, " \t")] = true
	}
	inA := map[string]bool{}
	for _, ln := range strings.Split(a, "\n") {
		inA[strings.TrimRight(ln, " \t")] = true
	}
	for _, ln := range strings.Split(a, "\n") {
		t := strings.TrimRight(ln, " \t")
		if t != "" && !inB[t] {
			onlyA = append(onlyA, t)
		}
	}
	for _, ln := range strings.Split(b, "\n") {
		t := strings.TrimRight(ln, " \t")
		if t != "" && !inA[t] {
			onlyB = append(onlyB, t)
		}
	}
	return onlyA, onlyB
}

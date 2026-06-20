package require

import (
	"context"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/nimling/samna-migrate/internal/db"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/sqlscan"
	"github.com/nimling/samna-migrate/internal/steps"
)

// Requirement is one object the deploy SQL needs the target database to provide
// before any statement can run. Kind is extension, language, or role.
type Requirement struct {
	Kind string
	Name string
}

var (
	rxExtension  = regexp.MustCompile(`(?i)\bCREATE\s+EXTENSION\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"([^"]+)"|([a-z0-9_]+))`)
	rxLanguage   = regexp.MustCompile(`(?i)\bLANGUAGE\s+(?:"([^"]+)"|([a-z0-9_]+))`)
	rxMakeLang   = regexp.MustCompile(`(?i)\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:TRUSTED\s+)?(?:PROCEDURAL\s+)?LANGUAGE\s+(?:"([^"]+)"|([a-z0-9_]+))`)
	rxMakeRole   = regexp.MustCompile(`(?i)\bCREATE\s+(?:ROLE|USER|GROUP)\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"([^"]+)"|([a-z0-9_]+))`)
	rxGrantTo    = regexp.MustCompile(`(?is)\bGRANT\b.*?\bTO\s+(.*?)(?:\bWITH\b|\bGRANTED\s+BY\b|;|$)`)
	rxRevokeFrom = regexp.MustCompile(`(?is)\bREVOKE\b.*?\bFROM\s+(.*?)(?:\bGRANTED\s+BY\b|\bCASCADE\b|\bRESTRICT\b|;|$)`)
	rxOwnerTo    = regexp.MustCompile(`(?i)\bOWNER\s+TO\s+(?:"([^"]+)"|([a-z0-9_]+))`)
	rxLeadWord   = regexp.MustCompile(`^[A-Za-z]+`)
	rxIdent      = regexp.MustCompile(`^[a-z_][a-z0-9_$]*$`)
)

const maxIdentLen = 63

var builtinLanguages = map[string]bool{
	"plpgsql": true, "sql": true, "c": true, "internal": true,
}

var builtinRoles = map[string]bool{
	"public": true, "current_user": true, "session_user": true,
	"current_role": true,
}

// Scan walks every active step's SQL and returns the net set of requirements:
// every referenced extension, plus languages and roles the SQL references but
// does not itself create. The set is deduped and sorted.
func Scan(stepsCfg *steps.Config, dbDir string) ([]Requirement, error) {
	reqExt := map[string]bool{}
	reqLang := map[string]bool{}
	reqRole := map[string]bool{}
	provLang := map[string]bool{}
	provRole := map[string]bool{}

	for _, st := range stepsCfg.Steps {
		if !st.Active() {
			continue
		}
		files, err := st.ResolveFiles(dbDir)
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			b, err := os.ReadFile(f.AbsPath)
			if err != nil {
				return nil, err
			}
			for _, stmt := range sqlscan.Statements(string(b)) {
				scanStatement(stmt, reqExt, reqLang, reqRole, provLang, provRole)
			}
		}
	}

	for name := range reqExt {
		provLang[name] = true
	}

	out := []Requirement{}
	for name := range reqExt {
		out = append(out, Requirement{Kind: "extension", Name: name})
	}
	for name := range reqLang {
		if builtinLanguages[name] || provLang[name] {
			continue
		}
		out = append(out, Requirement{Kind: "language", Name: name})
	}
	for name := range reqRole {
		if builtinRoles[name] || strings.HasPrefix(name, "pg_") || provRole[name] {
			continue
		}
		out = append(out, Requirement{Kind: "role", Name: name})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

func scanStatement(stmt string, reqExt, reqLang, reqRole, provLang, provRole map[string]bool) {
	lead := strings.ToUpper(rxLeadWord.FindString(strings.TrimSpace(stmt)))
	for _, m := range rxExtension.FindAllStringSubmatch(stmt, -1) {
		addName(reqExt, pick(m))
	}
	for _, m := range rxMakeLang.FindAllStringSubmatch(stmt, -1) {
		addName(provLang, pick(m))
	}
	for _, m := range rxMakeRole.FindAllStringSubmatch(stmt, -1) {
		addName(provRole, pick(m))
	}
	if lead == "CREATE" {
		for _, m := range rxLanguage.FindAllStringSubmatch(stmt, -1) {
			addName(reqLang, pick(m))
		}
	}
	if lead == "GRANT" {
		for _, m := range rxGrantTo.FindAllStringSubmatch(stmt, -1) {
			for _, r := range parseRoleList(m[1]) {
				reqRole[r] = true
			}
		}
	}
	if lead == "REVOKE" {
		for _, m := range rxRevokeFrom.FindAllStringSubmatch(stmt, -1) {
			for _, r := range parseRoleList(m[1]) {
				reqRole[r] = true
			}
		}
	}
	if lead == "ALTER" {
		for _, m := range rxOwnerTo.FindAllStringSubmatch(stmt, -1) {
			addName(reqRole, pick(m))
		}
	}
}

func pick(m []string) string {
	if m[1] != "" {
		return m[1]
	}
	return m[2]
}

func normalize(s string) string {
	return strings.ToLower(strings.TrimSpace(strings.Trim(s, `"`)))
}

func addName(set map[string]bool, raw string) {
	name := normalize(raw)
	if name == "" || len(name) > maxIdentLen {
		return
	}
	set[name] = true
}

func parseRoleList(s string) []string {
	out := []string{}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		part = strings.TrimPrefix(strings.ToLower(part), "group ")
		name := normalize(part)
		if name == "" || len(name) > maxIdentLen || !rxIdent.MatchString(name) {
			continue
		}
		out = append(out, name)
	}
	return out
}

// Verify returns the requirements the target database cannot satisfy: an
// extension absent from pg_available_extensions, a language absent from
// pg_language, or a role absent from pg_roles.
func Verify(ctx context.Context, d *db.DB, reqs []Requirement) ([]Requirement, error) {
	byKind := map[string][]string{}
	for _, r := range reqs {
		byKind[r.Kind] = append(byKind[r.Kind], r.Name)
	}
	query := map[string]string{
		"extension": `SELECT name FROM pg_available_extensions WHERE name = ANY($1)`,
		"language":  `SELECT lanname FROM pg_language WHERE lanname = ANY($1)`,
		"role":      `SELECT rolname FROM pg_roles WHERE rolname = ANY($1)`,
	}
	missing := []Requirement{}
	for kind, names := range byKind {
		present := map[string]bool{}
		rows, err := d.Pool.Query(ctx, query[kind], names)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				rows.Close()
				return nil, err
			}
			present[name] = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
		for _, name := range names {
			if !present[name] {
				missing = append(missing, Requirement{Kind: kind, Name: name})
			}
		}
	}
	sort.Slice(missing, func(i, j int) bool {
		if missing[i].Kind != missing[j].Kind {
			return missing[i].Kind < missing[j].Kind
		}
		return missing[i].Name < missing[j].Name
	})
	return missing, nil
}

// Record upserts the scanned set into samna_migrate.requirement and returns the
// requirements that were not recorded before this run.
func Record(ctx context.Context, d *db.DB, reqs []Requirement) ([]Requirement, error) {
	added := []Requirement{}
	for _, r := range reqs {
		var inserted bool
		err := d.Pool.QueryRow(ctx, `
			INSERT INTO samna_migrate.requirement (kind, name, last_seen)
			VALUES ($1, $2, now())
			ON CONFLICT (kind, name) DO UPDATE SET last_seen = now()
			RETURNING (xmax = 0)`, r.Kind, r.Name).Scan(&inserted)
		if err != nil {
			return nil, err
		}
		if inserted {
			added = append(added, r)
		}
	}
	return added, nil
}

// Gate scans, verifies, and records requirements for the deploy. A target that
// cannot satisfy a requirement stops the deploy. New requirements since the
// last run are reported.
func Gate(ctx context.Context, d *db.DB, stepsCfg *steps.Config, dbDir string) error {
	reqs, err := Scan(stepsCfg, dbDir)
	if err != nil {
		return err
	}
	missing, err := Verify(ctx, d, reqs)
	if err != nil {
		return err
	}
	if len(missing) > 0 {
		var b strings.Builder
		for _, m := range missing {
			b.WriteString("\n  ")
			b.WriteString(m.Kind)
			b.WriteString(" ")
			b.WriteString(m.Name)
		}
		return &MissingError{Missing: missing, detail: b.String()}
	}
	added, err := Record(ctx, d, reqs)
	if err != nil {
		return err
	}
	for _, a := range added {
		log.Warn("new requirement since last migrate: %s %s", a.Kind, a.Name)
	}
	return nil
}

// MissingError names every requirement the target database cannot satisfy.
type MissingError struct {
	Missing []Requirement
	detail  string
}

func (e *MissingError) Error() string {
	return "target database is missing required objects the deploy needs:" + e.detail
}

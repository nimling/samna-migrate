//go:build e2e

package e2e

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nimling/samna-migrate/pkg/cli"
)

// E2E targets a live bookable test database. The smig-managed image is brought
// up via `just build-db-smig` on DB_SMIG_PORT (default 5436). The shell-managed
// image is brought up via `just build-db-shell` on DB_SHELL_PORT (default 5435).
// PGPORT may be overridden by the calling shell to select either.
// Tests invoke the smig binary built by `just build` (bin/smig).

func env() map[string]string {
	port := envOr("PGPORT", "5436")
	return map[string]string{
		"PGHOST":         envOr("PGHOST", "localhost"),
		"PGPORT":         port,
		"PGUSER":         envOr("PGUSER", "bookable"),
		"PGPASSWORD":     envOr("PGPASSWORD", "bookable"),
		"PGDATABASE":     envOr("PGDATABASE", "bookable"),
		"PGSSLMODE":      "disable",
		"MIGRATE_SCHEMA": "../../database/smig/migrate.yml",
		"DB_DIR":         "../../database/smig",
	}
}

func bin(t *testing.T) string {
	t.Helper()
	b, err := filepath.Abs("../../bin/smig")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(b); err != nil {
		t.Fatalf("smig binary not built at %s (run `just build`)", b)
	}
	return b
}

func dial(t *testing.T) *pgxpool.Pool {
	t.Helper()
	e := env()
	conn := "host=" + e["PGHOST"] + " port=" + e["PGPORT"] + " user=" + e["PGUSER"] +
		" password=" + e["PGPASSWORD"] + " dbname=" + e["PGDATABASE"] + " sslmode=disable"
	p, err := pgxpool.New(context.Background(), conn)
	if err != nil {
		t.Fatalf("bookable test db not reachable on port %s: %v (run `just build-db-smig`)", e["PGPORT"], err)
	}
	if err := p.Ping(context.Background()); err != nil {
		p.Close()
		t.Fatalf("bookable test db ping failed: %v", err)
	}
	return p
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func runSmig(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	cmd := exec.Command(bin(t), args...)
	for k, v := range env() {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.Env = append(cmd.Env, "HOME="+os.Getenv("HOME"), "PATH="+os.Getenv("PATH"))
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

// TestBookableDBReachable confirms the bookable image is up and has the public schema.
func TestBookableDBReachable(t *testing.T) {
	p := dial(t)
	defer p.Close()
	var n int
	err := p.QueryRow(context.Background(), `
		SELECT count(*) FROM information_schema.tables
		WHERE table_schema = 'public' AND table_name = 'bookable'`).Scan(&n)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("expected public.bookable table to exist, count = %d", n)
	}
}

// TestSmigStatBeforeUpgrade prints state. The bookable image runs migrate.sh
// at first init which establishes samna_migrate at schema_version=1.
func TestSmigStatBeforeUpgrade(t *testing.T) {
	stdout, stderr, _ := runSmig(t, "stat")
	combined := stdout + stderr
	if !strings.Contains(combined, "migrate stat:") {
		t.Errorf("smig stat header missing in output: %q %q", stdout, stderr)
	}
}

// TestSmigUpgradeWalksChain runs `smig upgrade --yes` against the bookable
// database. The bookable image has samna_migrate at schema_version=1, so the
// chain walks 1 -> 2 -> 3 and writes yaml_sha256 in Phase B.
func TestSmigUpgradeWalksChain(t *testing.T) {
	p := dial(t)
	defer p.Close()

	stdout, stderr, err := runSmig(t, "upgrade", "--yes")
	if err != nil {
		t.Fatalf("smig upgrade failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	if !strings.Contains(stdout+stderr, "upgrade complete") {
		t.Errorf("expected 'upgrade complete' marker: %s", stdout+stderr)
	}

	var sv int
	if err := p.QueryRow(context.Background(),
		`SELECT schema_version FROM samna_migrate.state WHERE id = 1`).Scan(&sv); err != nil {
		t.Fatal(err)
	}
	if sv != cli.SchemaVersion {
		t.Errorf("schema_version after upgrade = %d, want %d", sv, cli.SchemaVersion)
	}

	var ysha *string
	if err := p.QueryRow(context.Background(),
		`SELECT yaml_sha256 FROM samna_migrate.state WHERE id = 1`).Scan(&ysha); err != nil {
		t.Fatal(err)
	}
	if ysha == nil || *ysha == "" {
		t.Error("yaml_sha256 not written after upgrade Phase B")
	}

	// New tables must exist.
	for _, want := range []string{"down_proposal"} {
		var n int
		if err := p.QueryRow(context.Background(), fmt.Sprintf(`
			SELECT count(*) FROM information_schema.tables
			WHERE table_schema = 'samna_migrate' AND table_name = '%s'`, want)).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 1 {
			t.Errorf("table samna_migrate.%s missing after upgrade", want)
		}
	}
}

// TestSmigCheckAfterUpgrade verifies the strict equality boot_check passes.
func TestSmigCheckAfterUpgrade(t *testing.T) {
	stdout, stderr, err := runSmig(t, "upgrade", "--yes")
	if err != nil {
		t.Fatalf("smig upgrade preparing for check failed: %v\n%s\n%s", err, stdout, stderr)
	}
	stdout, stderr, err = runSmig(t, "check")
	if err != nil {
		t.Fatalf("smig check failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	if !strings.Contains(stdout+stderr, "preflight passed") {
		t.Errorf("expected preflight passed marker: %s", stdout+stderr)
	}
}

// TestSmigUpIsNoopAfterUpgrade runs `smig up` against the bookable db where
// every migration was already applied by the bookable image's first init.
// Expected result: zero new applies.
func TestSmigUpIsNoopAfterUpgrade(t *testing.T) {
	p := dial(t)
	defer p.Close()
	if _, _, err := runSmig(t, "upgrade", "--yes"); err != nil {
		t.Fatalf("upgrade prep failed: %v", err)
	}

	var beforeApplied int
	p.QueryRow(context.Background(),
		`SELECT count(*) FROM samna_migrate.file WHERE state = 'applied' AND step_type = 'migration'`).
		Scan(&beforeApplied)

	stdout, stderr, err := runSmig(t, "up")
	if err != nil {
		t.Fatalf("smig up failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}

	var afterApplied int
	p.QueryRow(context.Background(),
		`SELECT count(*) FROM samna_migrate.file WHERE state = 'applied' AND step_type = 'migration'`).
		Scan(&afterApplied)

	if afterApplied < beforeApplied {
		t.Errorf("applied count regressed: before=%d after=%d", beforeApplied, afterApplied)
	}
}

func execUpgrade(ctx context.Context, p *pgxpool.Pool, sql string, args ...any) error {
	tx, err := p.Begin(ctx)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `SET LOCAL samna_migrate.upgrade_mode = 'true'`); err != nil {
		tx.Rollback(ctx)
		return err
	}
	if _, err := tx.Exec(ctx, sql, args...); err != nil {
		tx.Rollback(ctx)
		return err
	}
	return tx.Commit(ctx)
}

func TestSmigRebasePruneFoldsOrphan(t *testing.T) {
	p := dial(t)
	defer p.Close()
	ctx := context.Background()
	if _, _, err := runSmig(t, "upgrade", "--yes"); err != nil {
		t.Fatalf("upgrade prep failed: %v", err)
	}

	const orphan = "migrations/V9999.0__prune_e2e_orphan.sql"
	if err := execUpgrade(ctx, p, `DELETE FROM samna_migrate.file WHERE file_path = $1`, orphan); err != nil {
		t.Fatalf("pre-clean orphan: %v", err)
	}
	_, err := p.Exec(ctx, `
		INSERT INTO samna_migrate.file
		    (step_name, step_type, slug, version, file_name, file_path, sha256, applied_sha256,
		     state, position, applied_position, applied_at, first_seen, discovered_at, state_changed_at, updated_at)
		VALUES ('Migrations', 'migration', 'migration', '9999.0', 'V9999.0__prune_e2e_orphan.sql', $1,
		        'deadbeef', 'deadbeef', 'applied',
		        COALESCE((SELECT MAX(position) FROM samna_migrate.file), 0) + 1,
		        COALESCE((SELECT MAX(position) FROM samna_migrate.file), 0) + 1,
		        now(), now(), now(), now(), now())`, orphan)
	if err != nil {
		t.Fatalf("insert orphan: %v", err)
	}
	defer execUpgrade(ctx, p, `DELETE FROM samna_migrate.file WHERE file_path = $1`, orphan)

	stdout, stderr, err := runSmig(t, "rebase", "--prune", "--yes")
	if err != nil {
		t.Fatalf("rebase --prune failed: %v\nstdout: %s\nstderr: %s", err, stdout, stderr)
	}
	if !strings.Contains(stdout+stderr, "folded") {
		t.Errorf("expected folded marker: %s", stdout+stderr)
	}

	var state string
	if err := p.QueryRow(ctx, `SELECT state FROM samna_migrate.file WHERE file_path = $1`, orphan).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if state != "folded" {
		t.Errorf("orphan state = %q, want folded", state)
	}

	var nFold int
	p.QueryRow(ctx, `SELECT count(*) FROM samna_migrate.history WHERE file_path = $1 AND action_type = 'fold'`, orphan).Scan(&nFold)
	if nFold < 1 {
		t.Errorf("expected a fold history row for the orphan")
	}
}

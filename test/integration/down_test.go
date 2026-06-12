//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/nimling/samna-migrate/internal/agent"
	"github.com/nimling/samna-migrate/internal/anthropic"
	"github.com/nimling/samna-migrate/internal/apply"
	"github.com/nimling/samna-migrate/internal/preflight"
	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/steps"
	"github.com/nimling/samna-migrate/internal/testdb"
	"github.com/nimling/samna-migrate/internal/tools"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func TestDownAgentLoopWritesProposal(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}

	dbDir := t.TempDir()
	migDir := filepath.Join(dbDir, "migrations")
	os.MkdirAll(migDir, 0o755)
	forwardPath := filepath.Join(migDir, "V99.0__test_downme.sql")
	os.WriteFile(forwardPath, []byte("CREATE TABLE smig_dn (id INT);"), 0o644)

	yamlPath := filepath.Join(dbDir, "migrate.yml")
	os.WriteFile(yamlPath, []byte(`
name: smig-test
steps:
  - name: Migrations
    type: migration
    slug: migration
    schemas: [public]
    include:
      - path: migrations/
`), 0o644)

	snap, _ := schema.Snapshot(ctx, d, yamlPath)
	stepsCfg, err := steps.Load(yamlPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := preflight.Scan(ctx, d, snap, stepsCfg, dbDir); err != nil {
		t.Fatal(err)
	}
	pendings, _ := apply.ListPending(ctx, d)
	for _, p := range pendings {
		st, _ := apply.FileRel(stepsCfg, p.FilePath, dbDir)
		if err := apply.File(ctx, d, p, st, dbDir, cli.Version,
			os.Getenv("PGUSER"), "localhost", os.Getenv("PGDATABASE")); err != nil {
			t.Fatal(err)
		}
	}

	turn := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		turn++
		var resp anthropic.MessageResponse
		resp.Type = "message"
		resp.Role = "assistant"
		resp.Model = "claude-test"
		resp.StopReason = "tool_use"
		if turn == 1 {
			resp.Content = []anthropic.ContentBlock{{
				Type: "tool_use", ID: "u1", Name: "propose_down_sql",
				Input: json.RawMessage(`{"file_path":"migrations/V99.0__test_downme.sql","sql":"DROP TABLE IF EXISTS smig_dn;"}`),
			}}
		} else {
			resp.Content = []anthropic.ContentBlock{{
				Type: "tool_use", ID: "u2", Name: "commit_down",
				Input: json.RawMessage(`{"file_path":"migrations/V99.0__test_downme.sql"}`),
			}}
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	client := anthropic.New("fake")
	client.BaseURL = srv.URL
	tctx := tools.New(d, dbDir)
	loop := &agent.Loop{Client: client, Tools: tctx, Model: "claude-test"}

	result, err := loop.Run(ctx, "migrations/V99.0__test_downme.sql",
		"CREATE TABLE smig_dn (id INT);")
	if err != nil {
		t.Fatal(err)
	}
	if !result.Committed {
		t.Error("expected committed result")
	}
	if result.DownSQL != "DROP TABLE IF EXISTS smig_dn;" {
		t.Errorf("DownSQL = %q", result.DownSQL)
	}
}

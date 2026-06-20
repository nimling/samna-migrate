//go:build integration

package integration

import (
	"context"
	"testing"

	"github.com/nimling/samna-migrate/internal/schema"
	"github.com/nimling/samna-migrate/internal/testdb"
	"github.com/nimling/samna-migrate/internal/upgrade"
	"github.com/nimling/samna-migrate/pkg/cli"
)

func TestUpgradeChainEndToEnd(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}

	v, err := schema.GetSchemaVersion(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	if v != upgrade.TargetVersion {
		t.Errorf("schema_version after chain = %d, want %d", v, upgrade.TargetVersion)
	}

	assertColumn := func(table, col string) {
		ok, _ := d.ColumnExists(ctx, "samna_migrate", table, col)
		if !ok {
			t.Errorf("column missing: samna_migrate.%s.%s", table, col)
		}
	}
	assertColumn("state", "yaml_sha256")
	assertColumn("state", "yaml_observed_at")
	assertColumn("state", "tool_version")
	assertColumn("state", "schema_version")
	assertColumn("state", "last_started_at")
	assertColumn("state", "last_ended_at")

	assertColumn("file", "position")
	assertColumn("file", "applied_at")
	assertColumn("file", "applied_history_id")
	assertColumn("file", "applied_sha256")
	assertColumn("file", "applied_position")
	assertColumn("file", "drift_at")
	assertColumn("file", "renamed_at")
	assertColumn("file", "prior_file_path")
	assertColumn("file", "removed_at")

	assertColumn("history", "yaml_sha256")
	assertColumn("history", "position")
	assertColumn("history", "started_at")
	assertColumn("history", "ended_at")
	assertColumn("history", "undoing_history_id")

	assertColumn("down_proposal", "forward_sha256")
	assertColumn("down_proposal", "proposed_sql")
	assertColumn("down_proposal", "accepted_at")
	assertColumn("down_proposal", "succeeded")

	assertColumn("requirement", "kind")
	assertColumn("requirement", "name")
	assertColumn("requirement", "first_seen")
	assertColumn("requirement", "last_seen")

	assertConstraint(t, d, ctx, "file_state_check")
	assertConstraint(t, d, ctx, "requirement_kind_name_key")
	assertConstraint(t, d, ctx, "file_position_unique")
	assertConstraint(t, d, ctx, "history_action_type_check")
	assertConstraint(t, d, ctx, "history_success_no_error")
	assertConstraint(t, d, ctx, "file_applied_consistent")

	assertTrigger(t, d, ctx, "history_guard")
	assertTrigger(t, d, ctx, "file_guard")

	assertIndex(t, d, ctx, "file_position_idx")
	assertIndex(t, d, ctx, "history_started_at_idx")
	assertIndex(t, d, ctx, "down_proposal_file_id_idx")
}

func TestUpgradeChainIdempotent(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	// Force re-run by resetting schema_version
	d.Pool.Exec(ctx, `UPDATE samna_migrate.state SET schema_version = 0 WHERE id = 1`)
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatalf("re-running chain failed: %v", err)
	}
}

func TestYAMLShaRoundTrip(t *testing.T) {
	d := testdb.Open(t)
	ctx := context.Background()
	if err := schema.Ensure(ctx, d); err != nil {
		t.Fatal(err)
	}
	if err := upgrade.Chain(ctx, d, cli.Version); err != nil {
		t.Fatal(err)
	}
	if err := schema.WriteYAMLSha(ctx, d, "deadbeef"+padding(56), "smig-test"); err != nil {
		t.Fatal(err)
	}
	got, err := schema.GetYAMLSha(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	if got != "deadbeef"+padding(56) {
		t.Errorf("yaml_sha256 round-trip mismatch: %q", got)
	}
	tv, err := schema.GetToolVersion(ctx, d)
	if err != nil {
		t.Fatal(err)
	}
	if tv != "smig-test" {
		t.Errorf("tool_version: got %q", tv)
	}
}

func padding(n int) string {
	out := ""
	for i := 0; i < n; i++ {
		out += "0"
	}
	return out
}

package migrate

import (
	"context"
	"strings"
	"testing"
)

func TestDownRequiresKey(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "")
	downCmd.SetContext(context.Background())
	cmd := downCmd
	cmd.SetArgs([]string{"--to", "x.sql"})
	err := cmd.RunE(cmd, []string{})
	if err == nil || !strings.Contains(err.Error(), "ANTHROPIC_API_KEY") {
		t.Errorf("expected missing key error, got %v", err)
	}
}

func TestDownRequiresTarget(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "fake")
	downCmd.SetContext(context.Background())
	downTo, downSteps, downDryRun = "", 0, false
	err := downCmd.RunE(downCmd, []string{})
	if err == nil || !strings.Contains(err.Error(), "--to") {
		t.Errorf("expected target requirement, got %v", err)
	}
}

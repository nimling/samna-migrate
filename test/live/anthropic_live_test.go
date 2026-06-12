//go:build live

package live

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/nimling/samna-migrate/internal/anthropic"
)

// TestLiveAnthropicPing hits the real Anthropic Messages API with a minimal
// request to verify the configured key and model are accepted. Costs one
// inference call. Skipped unless ANTHROPIC_API_KEY is set AND -tags=live.
func TestLiveAnthropicPing(t *testing.T) {
	key := os.Getenv("ANTHROPIC_API_KEY")
	if key == "" {
		t.Skip("ANTHROPIC_API_KEY not set")
	}
	model := os.Getenv("ANTHROPIC_MODEL")
	if model == "" {
		model = "claude-sonnet-4-6"
	}
	c := anthropic.New(key)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	resp, err := c.CreateMessage(ctx, &anthropic.MessageRequest{
		Model:     model,
		MaxTokens: 16,
		Messages: []anthropic.Message{
			{Role: "user", Content: []anthropic.ContentBlock{
				{Type: "text", Text: "Reply with exactly: ok"},
			}},
		},
	})
	if err != nil {
		t.Fatalf("live API call failed: %v", err)
	}
	if len(resp.Content) == 0 {
		t.Errorf("response had no content blocks: %+v", resp)
	}
}

package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/nimling/samna-migrate/internal/anthropic"
	"github.com/nimling/samna-migrate/internal/tools"
)

func TestLoopMixedTextAndToolUse(t *testing.T) {
	var turn atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t := turn.Add(1)
		var resp anthropic.MessageResponse
		resp.Type = "message"
		resp.Role = "assistant"
		resp.Model = "claude-test"
		switch t {
		case 1:
			resp.StopReason = "tool_use"
			resp.Content = []anthropic.ContentBlock{
				{Type: "text", Text: "I will start by proposing"},
				{Type: "tool_use", ID: "u1", Name: "propose_down_sql",
					Input: json.RawMessage(`{"file_path":"f.sql","sql":"DROP TABLE t;"}`)},
			}
		case 2:
			resp.StopReason = "tool_use"
			resp.Content = []anthropic.ContentBlock{
				{Type: "tool_use", ID: "u2", Name: "commit_down",
					Input: json.RawMessage(`{"file_path":"f.sql"}`)},
			}
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := anthropic.New("k")
	c.BaseURL = srv.URL
	loop := &Loop{Client: c, Tools: tools.New(nil, ""), Model: "claude-test"}
	res, err := loop.Run(context.Background(), "f.sql", "CREATE TABLE t;")
	if err != nil {
		t.Fatal(err)
	}
	if !res.Committed || res.DownSQL != "DROP TABLE t;" {
		t.Errorf("result = %+v", res)
	}
}

func TestLoopHTTPError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(500)
		_, _ = w.Write([]byte(`{"error":{"type":"server_error","message":"oops"}}`))
	}))
	defer srv.Close()
	c := anthropic.New("k")
	c.BaseURL = srv.URL
	loop := &Loop{Client: c, Tools: tools.New(nil, ""), Model: "claude-test"}
	_, err := loop.Run(context.Background(), "f.sql", "")
	if err == nil || !strings.Contains(err.Error(), "anthropic 500") {
		t.Errorf("expected http 500 surface, got %v", err)
	}
}

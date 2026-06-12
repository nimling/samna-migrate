package agent

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nimling/samna-migrate/internal/anthropic"
	"github.com/nimling/samna-migrate/internal/tools"
)

func TestLoopCommits(t *testing.T) {
	turn := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = body
		turn++
		var resp anthropic.MessageResponse
		resp.ID = "msg_x"
		resp.Type = "message"
		resp.Role = "assistant"
		resp.Model = "claude-test"
		resp.StopReason = "tool_use"
		switch turn {
		case 1:
			resp.Content = []anthropic.ContentBlock{
				{Type: "tool_use", ID: "t1", Name: "propose_down_sql",
					Input: json.RawMessage(`{"file_path":"migrations/V5.0__schedule_arrays.sql","sql":"DROP TABLE booking;"}`)},
			}
		case 2:
			resp.Content = []anthropic.ContentBlock{
				{Type: "tool_use", ID: "t2", Name: "commit_down",
					Input: json.RawMessage(`{"file_path":"migrations/V5.0__schedule_arrays.sql"}`)},
			}
		default:
			http.Error(w, "unexpected turn", 500)
			return
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	client := anthropic.New("test")
	client.BaseURL = srv.URL
	tctx := tools.New(nil, "")
	loop := &Loop{Client: client, Tools: tctx, Model: "claude-test"}

	result, err := loop.Run(context.Background(), "migrations/V5.0__schedule_arrays.sql", "CREATE TABLE booking;")
	if err != nil {
		t.Fatal(err)
	}
	if !result.Committed {
		t.Error("expected committed")
	}
	if result.DownSQL != "DROP TABLE booking;" {
		t.Errorf("DownSQL = %q", result.DownSQL)
	}
	if result.FilePath != "migrations/V5.0__schedule_arrays.sql" {
		t.Errorf("FilePath = %q", result.FilePath)
	}
	if turn != 2 {
		t.Errorf("expected 2 turns, got %d", turn)
	}
}

func TestLoopEndsWithoutCommit(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := anthropic.MessageResponse{
			ID: "msg_x", Type: "message", Role: "assistant", Model: "claude-test",
			Content:    []anthropic.ContentBlock{{Type: "text", Text: "I give up"}},
			StopReason: "end_turn",
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	client := anthropic.New("test")
	client.BaseURL = srv.URL
	tctx := tools.New(nil, "")
	loop := &Loop{Client: client, Tools: tctx, Model: "claude-test"}
	_, err := loop.Run(context.Background(), "x.sql", "")
	if err == nil || !strings.Contains(err.Error(), "ended turn without committing") {
		t.Errorf("expected end-turn-without-commit error, got %v", err)
	}
}

func TestLoopRespectsMaxTurns(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Always return a benign tool_use that does not commit
		resp := anthropic.MessageResponse{
			ID: "x", Type: "message", Role: "assistant", Model: "m",
			Content: []anthropic.ContentBlock{
				{Type: "tool_use", ID: "x", Name: "propose_down_sql",
					Input: json.RawMessage(`{"file_path":"f.sql","sql":"-- noop"}`)},
			},
			StopReason: "tool_use",
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()
	client := anthropic.New("test")
	client.BaseURL = srv.URL
	loop := &Loop{Client: client, Tools: tools.New(nil, ""), Model: "m"}
	_, err := loop.Run(context.Background(), "f.sql", "")
	if err == nil || !strings.Contains(err.Error(), "exceeded 20 turns") {
		t.Errorf("expected max-turns error, got %v", err)
	}
}

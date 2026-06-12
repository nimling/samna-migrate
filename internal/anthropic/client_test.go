package anthropic

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCreateMessageHeaders(t *testing.T) {
	var captured *http.Request
	var capturedBody []byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		captured = r
		capturedBody, _ = io.ReadAll(r.Body)
		resp := MessageResponse{
			ID: "msg_1", Type: "message", Role: "assistant", Model: "claude-test",
			Content:    []ContentBlock{{Type: "text", Text: "ok"}},
			StopReason: "end_turn",
			Usage:      Usage{InputTokens: 5, OutputTokens: 3},
		}
		_ = json.NewEncoder(w).Encode(resp)
	}))
	defer srv.Close()

	c := New("test-key")
	c.BaseURL = srv.URL

	req := &MessageRequest{
		Model: "claude-test", MaxTokens: 100,
		Messages: []Message{
			{Role: "user", Content: []ContentBlock{{Type: "text", Text: "hi"}}},
		},
	}
	resp, err := c.CreateMessage(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	if captured.Header.Get("x-api-key") != "test-key" {
		t.Errorf("x-api-key = %q", captured.Header.Get("x-api-key"))
	}
	if captured.Header.Get("anthropic-version") != APIVersion {
		t.Errorf("anthropic-version = %q", captured.Header.Get("anthropic-version"))
	}
	if captured.Header.Get("content-type") != "application/json" {
		t.Errorf("content-type = %q", captured.Header.Get("content-type"))
	}
	if !strings.Contains(string(capturedBody), `"role":"user"`) {
		t.Errorf("body missing role: %s", capturedBody)
	}
	if resp.ID != "msg_1" || resp.StopReason != "end_turn" {
		t.Errorf("response decoded incorrectly: %+v", resp)
	}
	if resp.Usage.InputTokens != 5 || resp.Usage.OutputTokens != 3 {
		t.Errorf("usage decoded: %+v", resp.Usage)
	}
}

func TestCreateMessageAPIError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"type":"error","error":{"type":"authentication_error","message":"bad key"}}`))
	}))
	defer srv.Close()
	c := New("bad")
	c.BaseURL = srv.URL
	_, err := c.CreateMessage(context.Background(), &MessageRequest{Model: "x", MaxTokens: 1})
	if err == nil || !strings.Contains(err.Error(), "authentication_error") {
		t.Errorf("expected authentication_error, got %v", err)
	}
}

func TestCreateMessageMalformedResponse(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("not json"))
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	_, err := c.CreateMessage(context.Background(), &MessageRequest{Model: "x", MaxTokens: 1})
	if err == nil || !strings.Contains(err.Error(), "decode response") {
		t.Errorf("expected decode error, got %v", err)
	}
}

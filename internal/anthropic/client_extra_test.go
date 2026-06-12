package anthropic

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCreateMessageContextCancel(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(200 * time.Millisecond)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := c.CreateMessage(ctx, &MessageRequest{Model: "x", MaxTokens: 1})
	if err == nil {
		t.Error("expected context cancel error")
	}
}

func TestCreateMessageServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(503)
		_, _ = w.Write([]byte(`{"error":{"type":"overloaded_error","message":"slow down"}}`))
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	_, err := c.CreateMessage(context.Background(), &MessageRequest{Model: "x", MaxTokens: 1})
	if err == nil || !strings.Contains(err.Error(), "503") {
		t.Errorf("expected 503 error, got %v", err)
	}
}

func TestCreateMessageEmptyBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer srv.Close()
	c := New("k")
	c.BaseURL = srv.URL
	_, err := c.CreateMessage(context.Background(), &MessageRequest{Model: "x", MaxTokens: 1})
	if err == nil || !strings.Contains(err.Error(), "decode response") {
		t.Errorf("expected decode error on empty body, got %v", err)
	}
}

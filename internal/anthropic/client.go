package anthropic

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type Client struct {
	APIKey  string
	HTTP    *http.Client
	BaseURL string
	Version string
}

func New(apiKey string) *Client {
	return &Client{
		APIKey:  apiKey,
		HTTP:    &http.Client{Timeout: 5 * time.Minute},
		BaseURL: APIBase,
		Version: APIVersion,
	}
}

func (c *Client) CreateMessage(ctx context.Context, req *MessageRequest) (*MessageResponse, error) {
	body, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.BaseURL+"/messages", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	httpReq.Header.Set("x-api-key", c.APIKey)
	httpReq.Header.Set("anthropic-version", c.Version)
	httpReq.Header.Set("content-type", "application/json")

	resp, err := c.HTTP.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	rb, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		var apiErr struct {
			Error APIError `json:"error"`
		}
		_ = json.Unmarshal(rb, &apiErr)
		return nil, fmt.Errorf("anthropic %d %s: %s", resp.StatusCode, apiErr.Error.Type, apiErr.Error.Message)
	}
	var mr MessageResponse
	if err := json.Unmarshal(rb, &mr); err != nil {
		return nil, fmt.Errorf("decode response: %w (body=%s)", err, string(rb))
	}
	return &mr, nil
}

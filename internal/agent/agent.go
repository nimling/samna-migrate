package agent

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/nimling/samna-migrate/internal/anthropic"
	"github.com/nimling/samna-migrate/internal/log"
	"github.com/nimling/samna-migrate/internal/tools"
)

const SystemPrompt = `You are a Postgres migration reversal agent inside the smig CLI.

Goal: produce a SQL block that reverts the effects of the forward migration the operator names. Output via propose_down_sql, then call commit_down once you are satisfied.

Rules:
- Inspect the forward SQL with get_migration_file first.
- Inspect the current database state with the read-only tools to understand what exists right now.
- Write the down SQL to undo the forward migration's structural and data effects. Prefer IF EXISTS guards so partial applies do not break the revert.
- Wrap data writes that touch claimius-registered tables in SET LOCAL claimius.replay_mode='true' inside the same transaction.
- Validate the proposed SQL with validate_sql before committing.
- Stop after exactly one commit_down per agent run.

Style:
- Plain SQL only. No prose comments. No explanations outside the SQL.
`

type Loop struct {
	Client *anthropic.Client
	Tools  *tools.Ctx
	Model  string
}

type Result struct {
	FilePath  string
	DownSQL   string
	Committed bool
	Tokens    int
}

func (l *Loop) Run(ctx context.Context, filePath, forwardSQL string) (*Result, error) {
	defs := l.Tools.Schemas()
	anthropicTools := make([]anthropic.Tool, 0, len(defs))
	for _, d := range defs {
		anthropicTools = append(anthropicTools, anthropic.Tool{
			Name:        d.Name,
			Description: d.Description,
			InputSchema: d.InputSchema,
		})
	}

	userText := fmt.Sprintf("Forward migration file_path: %s\n\nForward SQL:\n%s\n\nSynthesize the reverse migration and commit.", filePath, forwardSQL)
	msgs := []anthropic.Message{
		{Role: "user", Content: []anthropic.ContentBlock{{Type: "text", Text: userText}}},
	}

	tokens := 0
	for turn := 0; turn < 20; turn++ {
		req := &anthropic.MessageRequest{
			Model:     l.Model,
			MaxTokens: 8192,
			System:    SystemPrompt,
			Messages:  msgs,
			Tools:     anthropicTools,
		}
		resp, err := l.Client.CreateMessage(ctx, req)
		if err != nil {
			return nil, err
		}
		tokens += resp.Usage.InputTokens + resp.Usage.OutputTokens

		msgs = append(msgs, anthropic.Message{Role: "assistant", Content: resp.Content})

		toolResults := []anthropic.ContentBlock{}
		committed := false
		for _, block := range resp.Content {
			if block.Type != "tool_use" {
				continue
			}
			log.Plain("    agent calls %s", block.Name)
			result, err := l.Tools.Dispatch(ctx, block.Name, block.Input)
			if err != nil {
				return nil, fmt.Errorf("tool %s: %w", block.Name, err)
			}
			resultJSON, _ := json.Marshal(result)
			toolResults = append(toolResults, anthropic.ContentBlock{
				Type:      "tool_result",
				ToolUseID: block.ID,
				Content:   string(resultJSON),
			})
			if block.Name == "commit_down" {
				committed = true
			}
		}

		if committed {
			sql, ok := l.Tools.AcceptedProposals[filePath]
			if !ok {
				return nil, fmt.Errorf("committed without a staged proposal for %s", filePath)
			}
			return &Result{
				FilePath:  filePath,
				DownSQL:   sql,
				Committed: true,
				Tokens:    tokens,
			}, nil
		}

		if resp.StopReason == "end_turn" && len(toolResults) == 0 {
			return nil, fmt.Errorf("model ended turn without committing")
		}

		msgs = append(msgs, anthropic.Message{Role: "user", Content: toolResults})
	}
	return nil, fmt.Errorf("agent loop exceeded 20 turns")
}

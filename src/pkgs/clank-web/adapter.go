package main

// The Claude Code adapter (design section 6): turns one line of Claude Code's
// stream-json output (events.jsonl) into Clankstation events, protocol v1.
// The GUI depends only on these, so harness changes stay in this file.
//
// Envelope: {"v":1, "seq":N, "type":..., ...}. seq is the 1-based line number
// in events.jsonl; events from the same line share it. It is also the SSE
// event id, so a client that reconnects resumes after the last line it saw.

import (
	"encoding/json"
	"path"
	"strings"
)

const ProtocolVersion = 1

type Event struct {
	V    int    `json:"v"`
	Seq  int    `json:"seq"`
	Type string `json:"type"` // turn, message, step, step_result, plan, result, state

	// turn
	Session string `json:"session,omitempty"`
	// message
	Text string `json:"text,omitempty"`
	// step, step_result
	StepID string `json:"step_id,omitempty"`
	Tool   string `json:"tool,omitempty"`
	Label  string `json:"label,omitempty"`
	Detail string `json:"detail,omitempty"`
	Error  bool   `json:"error,omitempty"`
	// plan
	Items []PlanItem `json:"items,omitempty"`
	// result
	Summary    string  `json:"summary,omitempty"`
	CostUSD    float64 `json:"cost_usd,omitempty"`
	DurationMS int64   `json:"duration_ms,omitempty"`
	// state (sent by the service, not from events.jsonl)
	State string `json:"state,omitempty"`
}

type PlanItem struct {
	Text   string `json:"text"`
	Status string `json:"status"` // pending, in_progress, completed
}

type rawEvent struct {
	Type      string  `json:"type"`
	Subtype   string  `json:"subtype"`
	SessionID string  `json:"session_id"`
	Result    string  `json:"result"`
	IsError   bool    `json:"is_error"`
	CostUSD   float64 `json:"total_cost_usd"`
	Duration  int64   `json:"duration_ms"`
	Message   struct {
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

type rawBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   bool            `json:"is_error"`
}

// Translate one events.jsonl line. Unknown or malformed lines give nothing.
func Translate(seq int, line []byte) []Event {
	var r rawEvent
	if len(strings.TrimSpace(string(line))) == 0 || json.Unmarshal(line, &r) != nil {
		return nil
	}
	ev := func(e Event) Event { e.V, e.Seq = ProtocolVersion, seq; return e }

	switch r.Type {
	case "system":
		if r.Subtype == "init" {
			return []Event{ev(Event{Type: "turn", Session: r.SessionID})}
		}
	case "assistant":
		var out []Event
		for _, b := range blocks(r.Message.Content) {
			switch b.Type {
			case "text":
				if t := strings.TrimSpace(b.Text); t != "" {
					out = append(out, ev(Event{Type: "message", Text: t}))
				}
			case "tool_use":
				out = append(out, ev(toolEvent(b)))
			}
		}
		return out
	case "user":
		var out []Event
		for _, b := range blocks(r.Message.Content) {
			if b.Type == "tool_result" {
				out = append(out, ev(Event{Type: "step_result", StepID: b.ToolUseID, Error: b.IsError}))
			}
		}
		return out
	case "result":
		return []Event{ev(Event{Type: "result", Summary: r.Result, Error: r.IsError,
			CostUSD: r.CostUSD, DurationMS: r.Duration})}
	}
	return nil
}

func blocks(raw json.RawMessage) []rawBlock {
	var bs []rawBlock
	if json.Unmarshal(raw, &bs) != nil {
		return nil // a plain string content (a prompt) has no blocks
	}
	return bs
}

func toolEvent(b rawBlock) Event {
	var in map[string]any
	_ = json.Unmarshal(b.Input, &in)
	str := func(k string) string { s, _ := in[k].(string); return s }
	file := displayPath(str("file_path"))
	if file == "" {
		file = displayPath(str("notebook_path"))
	}

	e := Event{Type: "step", StepID: b.ID, Tool: b.Name}
	switch b.Name {
	case "Read":
		e.Label = "Looking at " + file
	case "Grep":
		e.Label, e.Detail = "Searching the project", str("pattern")
	case "Glob":
		e.Label, e.Detail = "Looking for files", str("pattern")
	case "Edit", "MultiEdit", "NotebookEdit":
		e.Label = "Editing " + file
	case "Write":
		e.Label = "Writing " + file
	case "Bash":
		e.Detail = str("command")
		if d := strings.TrimSpace(str("description")); d != "" {
			e.Label = d
		} else {
			e.Label = "Running a command"
		}
	case "WebSearch", "WebFetch":
		e.Label = "Looking things up online"
		e.Detail = str("query") + str("url")
	case "Task", "Agent":
		e.Label = "Working on a side task"
		if d := str("description"); d != "" {
			e.Label += ": " + d
		}
	case "TodoWrite":
		return Event{Type: "plan", Items: todoItems(in["todos"])}
	default:
		name := b.Name
		if strings.HasPrefix(name, "mcp__") {
			parts := strings.Split(name, "__")
			name = parts[len(parts)-1]
		}
		e.Label = "Using " + name
	}
	if strings.HasSuffix(e.Label, " ") {
		e.Label = strings.TrimSpace(e.Label)
	}
	return e
}

func todoItems(v any) []PlanItem {
	list, _ := v.([]any)
	items := []PlanItem{}
	for _, x := range list {
		m, _ := x.(map[string]any)
		text, _ := m["content"].(string)
		status, _ := m["status"].(string)
		if text != "" {
			items = append(items, PlanItem{Text: text, Status: status})
		}
	}
	return items
}

// displayPath shows a path relative to the project (/workspace in the task).
func displayPath(p string) string {
	if p == "" {
		return ""
	}
	if rel, ok := strings.CutPrefix(p, "/workspace/"); ok {
		return rel
	}
	return path.Base(p)
}

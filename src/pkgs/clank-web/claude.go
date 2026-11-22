package main

// Claude Code's install and sign-in state for Settings (S3), from
// `clankctl harness status`: the installed version and `claude auth status`,
// both the harness's own report. Only these fields leave the box's API; the
// account's email and organization are not passed on.

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"
)

type ClaudeStatus struct {
	Installed bool   `json:"installed"`
	Version   string `json:"version,omitempty"`
	SignedIn  bool   `json:"signed_in"`
	Method    string `json:"method,omitempty"` // claude.ai, console, ...
	Plan      string `json:"plan,omitempty"`   // pro, max, ...
}

type claudeCache struct {
	mu     sync.Mutex
	at     time.Time
	status *ClaudeStatus
}

func (c *claudeCache) invalidate() {
	c.mu.Lock()
	c.status = nil
	c.mu.Unlock()
}

func (c *claudeCache) get(ctx context.Context, cl *Clankctl) (*ClaudeStatus, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.status != nil && time.Since(c.at) < 30*time.Second {
		return c.status, nil
	}
	out, err := cl.run(ctx, time.Minute, "", "harness", "status")
	if err != nil {
		return nil, err
	}
	st := parseHarnessStatus(out)
	c.status, c.at = st, time.Now()
	return st, nil
}

// parseHarnessStatus reads "claude: <version>" and the JSON that follows.
func parseHarnessStatus(out string) *ClaudeStatus {
	st := &ClaudeStatus{}
	first, rest, _ := strings.Cut(out, "\n")
	v, ok := strings.CutPrefix(strings.TrimSpace(first), "claude: ")
	if !ok || strings.HasPrefix(v, "not installed") {
		return st
	}
	st.Installed = true
	st.Version = strings.TrimSpace(strings.TrimSuffix(v, "(Claude Code)"))
	var auth struct {
		LoggedIn         bool   `json:"loggedIn"`
		AuthMethod       string `json:"authMethod"`
		SubscriptionType string `json:"subscriptionType"`
	}
	if i := strings.Index(rest, "{"); i >= 0 && json.Unmarshal([]byte(rest[i:]), &auth) == nil {
		st.SignedIn = auth.LoggedIn
		st.Method = auth.AuthMethod
		st.Plan = auth.SubscriptionType
	}
	return st
}

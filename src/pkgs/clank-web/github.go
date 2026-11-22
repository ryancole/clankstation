package main

// GitHub (S10, design 8.2): the sign-in state for Settings, a task's pull
// request, and the per-project setting.
//
//   GET  /api/github                       {signed_in, login}
//   POST /api/projects/{name}/pull-requests {on}
//
// The sign-in is GitHub's own (gh, in the user's home volume); the box only
// asks gh whether it's signed in and as whom (`clankctl github status`). A
// task's pull request comes from result/pr.json, which the runner writes after
// each turn; `clankctl pr refresh` checks GitHub for a merge or close.

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type GitHubStatus struct {
	SignedIn bool   `json:"signed_in"`
	Login    string `json:"login,omitempty"`
}

type githubCache struct {
	mu     sync.Mutex
	at     time.Time
	status *GitHubStatus
}

func (g *githubCache) invalidate() {
	g.mu.Lock()
	g.status = nil
	g.mu.Unlock()
}

func (g *githubCache) get(ctx context.Context, c *Clankctl) (*GitHubStatus, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.status != nil && time.Since(g.at) < 30*time.Second {
		return g.status, nil
	}
	out, err := c.run(ctx, time.Minute, "", "github", "status")
	if err != nil {
		return nil, err
	}
	st := parseGitHubStatus(out)
	g.status, g.at = st, time.Now()
	return st, nil
}

// parseGitHubStatus reads `gh auth status --json hosts`: the active
// github.com account, if its state is "success".
func parseGitHubStatus(out string) *GitHubStatus {
	var v struct {
		Hosts map[string][]struct {
			State  string `json:"state"`
			Active bool   `json:"active"`
			Login  string `json:"login"`
		} `json:"hosts"`
	}
	st := &GitHubStatus{}
	if i := strings.Index(out, "{"); i < 0 || json.Unmarshal([]byte(out[i:]), &v) != nil {
		return st
	}
	for _, a := range v.Hosts["github.com"] {
		if a.Active && a.State == "success" {
			st.SignedIn, st.Login = true, a.Login
		}
	}
	return st
}

// PullRequest is a task's pull request, for the task page and list.
type PullRequest struct {
	Number int    `json:"number,omitempty"`
	URL    string `json:"url,omitempty"`
	State  string `json:"state,omitempty"` // draft, open, merged, closed
	Branch string `json:"branch,omitempty"`
	Error  string `json:"error,omitempty"` // why the last turn wasn't pushed
}

func readPullRequest(dir string) *PullRequest {
	b, err := os.ReadFile(filepath.Join(dir, "result", "pr.json"))
	if err != nil {
		return nil
	}
	var v struct {
		Number  int    `json:"number"`
		URL     string `json:"url"`
		State   string `json:"state"`
		IsDraft bool   `json:"isDraft"`
		Branch  string `json:"branch"`
		Error   string `json:"error"`
	}
	if json.Unmarshal(b, &v) != nil {
		return nil
	}
	pr := &PullRequest{Number: v.Number, URL: v.URL, Branch: v.Branch, Error: v.Error}
	switch {
	case v.State == "MERGED":
		pr.State = "merged"
	case v.State == "CLOSED":
		pr.State = "closed"
	case v.IsDraft:
		pr.State = "draft"
	case v.State == "OPEN":
		pr.State = "open"
	}
	return pr
}

// prRefresher checks an open pull request on GitHub at most once a minute
// per task, in the background, when its page is looked at.
type prRefresher struct {
	mu   sync.Mutex
	last map[string]time.Time
}

func (p *prRefresher) maybe(c *Clankctl, s *Store, id string, pr *PullRequest) {
	if pr == nil || pr.Number == 0 || pr.State == "merged" || pr.State == "closed" {
		return
	}
	p.mu.Lock()
	if p.last == nil {
		p.last = map[string]time.Time{}
	}
	if time.Since(p.last[id]) < time.Minute {
		p.mu.Unlock()
		return
	}
	p.last[id] = time.Now()
	p.mu.Unlock()
	go func() {
		_, _ = c.run(context.Background(), time.Minute, "", "pr", "refresh", id)
		s.invalidate()
	}()
}

// githubURL: pull requests are on by default for these remotes (as in clankctl).
func githubURL(url string) bool {
	for _, p := range []string{"https://github.com/", "git@github.com:", "ssh://git@github.com/"} {
		if strings.HasPrefix(url, p) {
			return true
		}
	}
	return false
}

// SetPullRequests turns a project's pull requests on or off.
func (c *Clankctl) SetPullRequests(ctx context.Context, name string, on bool) error {
	if !validName(name) {
		return &ActionError{"There's no such project."}
	}
	v := "off"
	if on {
		v = "on"
	}
	_, err := c.run(ctx, time.Minute, "", "project", "set", name, "pull-requests", v)
	return err
}

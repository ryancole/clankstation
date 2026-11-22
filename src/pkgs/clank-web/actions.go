package main

// Actions (S2). Every change goes through clankctl, which stays the one
// writer of the data tree; the service runs it as the same service user.

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type Clankctl struct {
	Path string // the clankctl executable
	User string // household user (CLANK_USER) for new tasks
}

// ActionError is a failed clankctl command, with its message for the user.
type ActionError struct{ Msg string }

func (e *ActionError) Error() string { return e.Msg }

var taskIDInOutput = regexp.MustCompile(`(?m)^(t-[0-9]{8}-[0-9]{6}-[0-9a-f]{4})$`)

// run executes clankctl with args and an optional stdin, and turns a
// failure into an ActionError carrying clankctl's own message.
func (c *Clankctl) run(ctx context.Context, timeout time.Duration, stdin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, c.Path, args...)
	cmd.Env = append(os.Environ(), "CLANK_USER="+c.User)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	// A devcontainer task keeps preparing in the background after clankctl
	// returns; don't wait on pipes that process holds open.
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return "", &ActionError{"This took too long and was stopped."}
		}
		return "", &ActionError{clankctlMessage(stderr.String(), err)}
	}
	return stdout.String(), nil
}

// clankctlMessage picks clankctl's "clankctl: ..." line from stderr.
func clankctlMessage(stderr string, err error) string {
	lines := strings.Split(strings.TrimSpace(stderr), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if msg, ok := strings.CutPrefix(lines[i], "clankctl: "); ok {
			return msg
		}
	}
	if s := strings.TrimSpace(stderr); s != "" {
		return lines[len(lines)-1]
	}
	return err.Error()
}

// NewTask starts a task and returns its id. The prompt goes on stdin
// (`clankctl run <project> -`), so any text is safe.
func (c *Clankctl) NewTask(ctx context.Context, project, prompt string) (string, error) {
	if strings.TrimSpace(prompt) == "" {
		return "", &ActionError{"Write what Claude should do."}
	}
	if !validName(project) {
		return "", &ActionError{"Pick a project."}
	}
	out, err := c.run(ctx, 2*time.Minute, prompt, "run", project, "-")
	if err != nil {
		return "", err
	}
	m := taskIDInOutput.FindStringSubmatch(out)
	if m == nil {
		return "", &ActionError{"The task started, but the box didn't say which one it is."}
	}
	return m[1], nil
}

// Reply starts the next turn in the task's session (`clankctl resume`).
func (c *Clankctl) Reply(ctx context.Context, id, prompt string) error {
	if strings.TrimSpace(prompt) == "" {
		return &ActionError{"Write a reply first."}
	}
	_, err := c.run(ctx, 2*time.Minute, prompt, "resume", id, "-")
	return err
}

// Stop stops a running task; clankctl waits for it to save its work.
func (c *Clankctl) Stop(ctx context.Context, id string) error {
	_, err := c.run(ctx, 2*time.Minute, "", "stop", id)
	return err
}

// AddProject clones a repository onto the box (`clankctl project add`).
func (c *Clankctl) AddProject(ctx context.Context, name, url string) error {
	if !validName(name) {
		return &ActionError{"Project names use lowercase letters, digits, - and _, and start with a letter or digit."}
	}
	url = strings.TrimSpace(url)
	if url == "" || strings.HasPrefix(url, "-") {
		return &ActionError{"Enter the address you'd use to clone the repository."}
	}
	_, err := c.run(ctx, 15*time.Minute, "", "project", "add", name, url)
	return err
}

var namePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

func validName(s string) bool { return namePattern.MatchString(s) }

type Project struct {
	Name     string `json:"name"`
	URL      string `json:"url"`
	Template string `json:"template"`
	LastUsed string `json:"last_used,omitempty"` // newest task's creation time
}

// Projects lists projects/*/project.env, the most recently used first.
func (s *Store) Projects() []Project {
	entries, _ := os.ReadDir(filepath.Join(s.Data, "projects"))
	last := map[string]string{}
	tasks, _ := os.ReadDir(s.tasksDir())
	for _, t := range tasks {
		if !taskIDPattern.MatchString(t.Name()) {
			continue
		}
		env := readKV(filepath.Join(s.tasksDir(), t.Name(), "task.env"))
		if p, c := env["project"], env["created"]; p != "" && c > last[p] {
			last[p] = c
		}
	}
	out := []Project{}
	for _, e := range entries {
		env := filepath.Join(s.Data, "projects", e.Name(), "project.env")
		if !validName(e.Name()) || !fileExists(env) {
			continue
		}
		kv := readKV(env)
		out = append(out, Project{Name: e.Name(), URL: kv["url"], Template: kv["template"], LastUsed: last[e.Name()]})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].LastUsed != out[j].LastUsed {
			return out[i].LastUsed > out[j].LastUsed
		}
		return out[i].Name < out[j].Name
	})
	return out
}

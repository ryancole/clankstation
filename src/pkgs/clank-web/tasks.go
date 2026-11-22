package main

// Reading tasks from the data tree (design section 5.3). The service only
// reads here; clankctl stays the writer of every task file.

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

var taskIDPattern = regexp.MustCompile(`^t-[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$`)

// Task states as the GUI sees them (docs/gui.md section 2). The box's own
// states, plus interactive (running, taken over) and needs_input (done, and
// the summary asks a question).
const (
	StatePreparing   = "preparing"
	StateRunning     = "running"
	StateInteractive = "interactive"
	StateNeedsInput  = "needs_input"
	StateDone        = "done"
	StateFailed      = "failed"
	StateStopped     = "stopped"
	StateLost        = "lost"
)

type Store struct {
	Data    string // /var/lib/clankstation
	Running func() (map[string]bool, error)
}

func (s *Store) tasksDir() string { return filepath.Join(s.Data, "tasks") }

func (s *Store) taskDir(id string) (string, bool) {
	if !taskIDPattern.MatchString(id) {
		return "", false
	}
	d := filepath.Join(s.tasksDir(), id)
	if _, err := os.Stat(filepath.Join(d, "task.env")); err != nil {
		return "", false
	}
	return d, true
}

// readKV reads a key=value file such as task.env or project.env.
func readKV(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), "=")
		if ok {
			if _, seen := out[k]; !seen {
				out[k] = v
			}
		}
	}
	return out
}

type Status struct {
	State     string `json:"state"`
	Mode      string `json:"mode"`
	ExitCode  int    `json:"exit_code"`
	SessionID string `json:"session_id"`
	Started   string `json:"started"`
	Finished  string `json:"finished"`
}

func readStatus(dir string) (*Status, error) {
	b, err := os.ReadFile(filepath.Join(dir, "status.json"))
	if err != nil {
		return nil, err
	}
	var st Status
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

// Turn is one entry of prompts.log: "--- <time> <kind>" and the prompt lines.
type Turn struct {
	Time   string `json:"time"`
	Kind   string `json:"kind"` // run, resume, attach
	Prompt string `json:"prompt"`
}

func readTurns(dir string) []Turn {
	f, err := os.Open(filepath.Join(dir, "prompts.log"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var turns []Turn
	var lines []string
	flush := func() {
		if len(turns) > 0 {
			turns[len(turns)-1].Prompt = strings.TrimRight(strings.Join(lines, "\n"), "\n")
		}
		lines = nil
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if rest, ok := strings.CutPrefix(line, "--- "); ok {
			if when, kind, ok := strings.Cut(rest, " "); ok && isTurnKind(kind) {
				flush()
				turns = append(turns, Turn{Time: when, Kind: kind})
				continue
			}
		}
		lines = append(lines, line)
	}
	flush()
	return turns
}

func isTurnKind(k string) bool { return k == "run" || k == "resume" || k == "attach" }

// processAlive reports whether pid exists (EPERM still means it exists).
func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// boxState mirrors clankctl's task_state: running container, live prepare
// process, status.json, else lost.
func boxState(dir string, running bool) (string, *Status) {
	st, _ := readStatus(dir)
	if running {
		return StateRunning, st
	}
	if b, err := os.ReadFile(filepath.Join(dir, "prepare.pid")); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && processAlive(pid) {
			return StatePreparing, st
		}
	}
	if st != nil && st.State != "" {
		return st.State, st
	}
	return StateLost, st
}

type TaskSummary struct {
	ID       string `json:"id"`
	Project  string `json:"project"`
	Title    string `json:"title"`
	State    string `json:"state"`
	Archived bool   `json:"archived"`
	Created  string `json:"created"`
	Finished string `json:"finished,omitempty"`
	// One line for the card: the current step while working, the question
	// when it needs an answer, else the summary's first sentence.
	Activity string `json:"activity,omitempty"`
}

type TaskDetail struct {
	TaskSummary
	Branch   string  `json:"branch"`
	Env      string  `json:"env"`
	Summary  string  `json:"summary"`
	Question string  `json:"question,omitempty"`
	Turns    []Turn  `json:"turns"`
	Files    []File  `json:"files"`
	Status   *Status `json:"status,omitempty"`
}

func (s *Store) running() map[string]bool {
	if s.Running == nil {
		return map[string]bool{}
	}
	m, err := s.Running()
	if err != nil {
		return map[string]bool{}
	}
	return m
}

func (s *Store) List() []TaskSummary {
	entries, _ := os.ReadDir(s.tasksDir())
	run := s.running()
	out := []TaskSummary{}
	for _, e := range entries {
		dir, ok := s.taskDir(e.Name())
		if !ok {
			continue
		}
		out = append(out, s.summary(e.Name(), dir, run[e.Name()]).TaskSummary)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })
	return out
}

func (s *Store) Get(id string) (*TaskDetail, bool) {
	dir, ok := s.taskDir(id)
	if !ok {
		return nil, false
	}
	d := s.summary(id, dir, s.running()[id])
	d.Files = readFiles(dir)
	return &d, true
}

func (s *Store) summary(id, dir string, running bool) TaskDetail {
	env := readKV(filepath.Join(dir, "task.env"))
	turns := readTurns(dir)
	state, st := boxState(dir, running)
	if state == StateRunning && len(turns) > 0 && turns[len(turns)-1].Kind == "attach" {
		state = StateInteractive
	}
	summaryText := ""
	if b, err := os.ReadFile(filepath.Join(dir, "result", "summary.md")); err == nil {
		summaryText = strings.TrimSpace(string(b))
	}
	question := ""
	if state == StateDone {
		if q := trailingQuestion(summaryText); q != "" {
			state, question = StateNeedsInput, q
		}
	}

	title := ""
	if len(turns) > 0 {
		title = firstLine(turns[0].Prompt)
	} else if b, err := os.ReadFile(filepath.Join(dir, "prompt.txt")); err == nil {
		title = firstLine(string(b))
	}

	d := TaskDetail{
		TaskSummary: TaskSummary{
			ID:       id,
			Project:  env["project"],
			Title:    title,
			State:    state,
			Archived: fileExists(filepath.Join(dir, "pruned")),
			Created:  env["created"],
		},
		Branch:   env["branch"],
		Env:      env["env"],
		Summary:  summaryText,
		Question: question,
		Turns:    turns,
		Status:   st,
	}
	if st != nil && state != StateRunning && state != StateInteractive && state != StatePreparing {
		d.Finished = st.Finished
	}
	switch state {
	case StateRunning, StatePreparing, StateInteractive:
		d.Activity = latestStep(filepath.Join(dir, "events.jsonl"))
	case StateNeedsInput:
		d.Activity = question
	default:
		d.Activity = firstSentence(summaryText)
	}
	return d
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	line, _, _ := strings.Cut(s, "\n")
	return strings.TrimSpace(line)
}

var (
	paraBreak    = regexp.MustCompile(`\n\s*\n`)
	codeSpan     = regexp.MustCompile("`[^`]*`")
	questionMark = regexp.MustCompile(`\?(\s|$|["'”’*_)\]])`)
)

// trailingQuestion returns the summary's last paragraph if a sentence in it
// is a question ("Do you want a fourth fact? If so, ..."), ignoring code
// and URLs (docs/gui.md: "Needs your answer", first version).
func trailingQuestion(summary string) string {
	s := strings.TrimSpace(summary)
	if s == "" {
		return ""
	}
	paras := paraBreak.Split(s, -1)
	last := strings.TrimSpace(paras[len(paras)-1])
	if questionMark.MatchString(codeSpan.ReplaceAllString(last, "")) {
		return last
	}
	return ""
}

func firstSentence(s string) string {
	s = firstLine(strings.TrimLeft(s, "# \n"))
	if i := strings.IndexAny(s, ".!?"); i >= 0 && i < len(s)-1 {
		return s[:i+1]
	}
	return s
}

// latestStep reads the end of events.jsonl and returns the newest step's
// plain-language label.
func latestStep(path string) string {
	lines := tailLines(path, 64*1024)
	for i := len(lines) - 1; i >= 0; i-- {
		evs := Translate(0, []byte(lines[i]))
		for j := len(evs) - 1; j >= 0; j-- {
			if evs[j].Type == "step" {
				return evs[j].Label
			}
		}
	}
	return ""
}

func tailLines(path string, max int64) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil
	}
	off := fi.Size() - max
	if off < 0 {
		off = 0
	}
	buf := make([]byte, fi.Size()-off)
	if _, err := f.ReadAt(buf, off); err != nil && len(buf) == 0 {
		return nil
	}
	lines := strings.Split(string(buf), "\n")
	if off > 0 && len(lines) > 0 {
		lines = lines[1:] // partial first line
	}
	return lines
}

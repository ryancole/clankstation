package main

// Browser terminals (S3): a clankctl command under a PTY, relayed over a
// WebSocket. Kinds:
//   attach   clankctl attach --yes <task>   take over a task (Claude Code's
//                                          own interactive screen)
//   login    clankctl login claude          Claude's own sign-in
//   install  clankctl harness enable claude the official installer
//
// The service relays bytes and never reads, logs or stores them (design
// section 3, "Sign-in from the browser"). The only copy is the scrollback
// held in memory while the session is open, so a page that reconnects (a
// phone that slept) sees the screen again; it goes when the session ends.
//
// WebSocket protocol: binary frames carry terminal bytes both ways. Text
// frames carry JSON control messages:
//   client -> box  {"type":"resize","cols":N,"rows":N}  {"type":"end"}
//   box -> client  {"type":"exit","code":N}  (then the socket closes)

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"github.com/creack/pty"
)

const (
	scrollbackBytes = 256 << 10
	idleAttach      = 30 * time.Minute // no page open: hand the task back
	idleOther       = 10 * time.Minute // no page open: end a sign-in or install
)

type Terminals struct {
	c        *Clankctl
	mu       sync.Mutex
	sessions map[string]*Session
	onExit   func(kind, task string) // after a session ends
}

type Session struct {
	kind, task string
	cmd        *exec.Cmd
	pty        *os.File
	done       chan struct{}
	exitCode   int

	mu         sync.Mutex
	scrollback []byte
	sub        chan []byte // the one connected page, if any
	lastSeen   time.Time
	ending     bool
}

func NewTerminals(c *Clankctl, onExit func(kind, task string)) *Terminals {
	t := &Terminals{c: c, sessions: map[string]*Session{}, onExit: onExit}
	go t.reap()
	return t
}

func termArgs(kind, task string) ([]string, bool) {
	switch kind {
	case "attach":
		if !taskIDPattern.MatchString(task) {
			return nil, false
		}
		return []string{"attach", "--yes", task}, true
	case "login":
		return []string{"login", "claude"}, true
	case "install":
		return []string{"harness", "enable", "claude"}, true
	}
	return nil, false
}

func sessionKey(kind, task string) string { return kind + ":" + task }

// Open returns the running session of this kind (and task), or starts one.
func (t *Terminals) Open(kind, task string) (*Session, error) {
	args, ok := termArgs(kind, task)
	if !ok {
		return nil, &ActionError{"Unknown terminal."}
	}
	if kind != "attach" {
		task = ""
	}
	key := sessionKey(kind, task)
	t.mu.Lock()
	defer t.mu.Unlock()
	if s, ok := t.sessions[key]; ok {
		return s, nil
	}
	cmd := exec.Command(t.c.Path, args...)
	cmd.Env = append(os.Environ(), "CLANK_USER="+t.c.User, "TERM=xterm-256color", "COLORTERM=truecolor")
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: 30, Cols: 100})
	if err != nil {
		return nil, err
	}
	s := &Session{kind: kind, task: task, cmd: cmd, pty: f, done: make(chan struct{}), lastSeen: time.Now()}
	t.sessions[key] = s
	go s.pump()
	go func() {
		err := cmd.Wait()
		s.exitCode = exitCode(err)
		// Let pump drain what's left before the page hears "exit".
		time.Sleep(200 * time.Millisecond)
		f.Close()
		t.mu.Lock()
		delete(t.sessions, key)
		t.mu.Unlock()
		close(s.done)
		if t.onExit != nil {
			t.onExit(kind, task)
		}
	}()
	return s, nil
}

func exitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	if err != nil {
		return -1
	}
	return 0
}

// Has reports whether a session of this kind (and task) is open.
func (t *Terminals) Has(kind, task string) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	_, ok := t.sessions[sessionKey(kind, task)]
	return ok
}

type TermInfo struct {
	Kind string `json:"kind"`
	Task string `json:"task,omitempty"`
}

func (t *Terminals) List() []TermInfo {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := []TermInfo{}
	for _, s := range t.sessions {
		out = append(out, TermInfo{Kind: s.kind, Task: s.task})
	}
	return out
}

// pump copies PTY output to the scrollback and the connected page.
func (s *Session) pump() {
	buf := make([]byte, 32<<10)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			b := append([]byte(nil), buf[:n]...)
			s.mu.Lock()
			s.scrollback = append(s.scrollback, b...)
			if over := len(s.scrollback) - scrollbackBytes; over > 0 {
				s.scrollback = append([]byte(nil), s.scrollback[over:]...)
			}
			if s.sub != nil {
				select {
				case s.sub <- b:
				default: // a page that can't keep up reconnects and replays
					close(s.sub)
					s.sub = nil
				}
			}
			s.mu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

// subscribe makes this page the session's one viewer (a second page takes
// over from the first) and returns the screen so far.
func (s *Session) subscribe() ([]byte, chan []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sub != nil {
		close(s.sub)
	}
	s.sub = make(chan []byte, 512)
	return append([]byte(nil), s.scrollback...), s.sub
}

func (s *Session) unsubscribe(ch chan []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sub == ch {
		close(s.sub)
		s.sub = nil
	}
	s.lastSeen = time.Now()
}

func (s *Session) write(b string) { _, _ = s.pty.Write([]byte(b)) }

// End finishes the session the way a person would. Taking over: interrupt
// Claude, then /exit, so clankctl hands the task back with its diff
// refreshed. A sign-in or install: Ctrl-C. Then harder, if it hangs.
func (s *Session) End() {
	s.mu.Lock()
	if s.ending {
		s.mu.Unlock()
		return
	}
	s.ending = true
	s.mu.Unlock()
	type step struct {
		wait time.Duration
		do   func()
	}
	var steps []step
	if s.kind == "attach" {
		steps = []step{
			{0, func() { s.write("\x1b") }},                             // Esc: stop what Claude is doing
			{400 * time.Millisecond, func() { s.write("\x15/exit\r") }}, // clear the input, /exit
			{15 * time.Second, func() { s.write("\x03") }},              // Ctrl-C twice quits
			{500 * time.Millisecond, func() { s.write("\x03") }},
		}
	} else {
		steps = []step{{0, func() { s.write("\x03") }}}
	}
	steps = append(steps, step{15 * time.Second, func() { _ = s.cmd.Process.Signal(syscall.SIGTERM) }})
	go func() {
		for _, st := range steps {
			select {
			case <-s.done:
				return
			case <-time.After(st.wait):
				st.do()
			}
		}
	}()
}

// reap ends sessions nobody has looked at for a while.
func (t *Terminals) reap() {
	for range time.Tick(time.Minute) {
		t.mu.Lock()
		var idle []*Session
		for _, s := range t.sessions {
			s.mu.Lock()
			limit := idleOther
			if s.kind == "attach" {
				limit = idleAttach
			}
			if s.sub == nil && time.Since(s.lastSeen) > limit {
				idle = append(idle, s)
			}
			s.mu.Unlock()
		}
		t.mu.Unlock()
		for _, s := range idle {
			s.End()
		}
	}
}

type termControl struct {
	Type string `json:"type"`
	Cols int    `json:"cols,omitempty"`
	Rows int    `json:"rows,omitempty"`
	Code int    `json:"code"`
}

// ServeWS connects a page to the session. websocket.Accept refuses other
// origins, so another site's page can't open a terminal on the box.
func (t *Terminals) ServeWS(w http.ResponseWriter, r *http.Request, s *Session) {
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(1 << 20)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	screen, ch := s.subscribe()
	defer s.unsubscribe(ch)

	// Page -> PTY.
	go func() {
		defer cancel()
		for {
			typ, b, err := conn.Read(ctx)
			if err != nil {
				return
			}
			if typ == websocket.MessageBinary {
				_, _ = s.pty.Write(b)
				continue
			}
			var c termControl
			if json.Unmarshal(b, &c) != nil {
				continue
			}
			switch c.Type {
			case "resize":
				if c.Cols > 0 && c.Rows > 0 && c.Cols < 1000 && c.Rows < 1000 {
					_ = pty.Setsize(s.pty, &pty.Winsize{Cols: uint16(c.Cols), Rows: uint16(c.Rows)})
				}
			case "end":
				s.End()
			}
		}
	}()

	// PTY -> page: the screen so far, then live output.
	if len(screen) > 0 {
		if conn.Write(ctx, websocket.MessageBinary, screen) != nil {
			return
		}
	}
	for {
		select {
		case <-ctx.Done():
			conn.CloseNow()
			return
		case b, ok := <-ch:
			if !ok {
				// Another page took over, or this one fell behind.
				conn.Close(websocket.StatusGoingAway, "replaced")
				return
			}
			if conn.Write(ctx, websocket.MessageBinary, b) != nil {
				return
			}
		case <-s.done:
			// Send what's left, then say how it ended.
		drain:
			for {
				select {
				case b, ok := <-ch:
					if !ok {
						break drain
					}
					_ = conn.Write(ctx, websocket.MessageBinary, b)
				default:
					break drain
				}
			}
			msg, _ := json.Marshal(termControl{Type: "exit", Code: s.exitCode})
			_ = conn.Write(ctx, websocket.MessageText, msg)
			conn.Close(websocket.StatusNormalClosure, "exited")
			return
		}
	}
}

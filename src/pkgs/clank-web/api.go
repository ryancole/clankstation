package main

// HTTP API, protocol v1:
//   GET /api/tasks               task cards for Home
//   GET /api/tasks/{id}          one task: state, summary, turns, changed files
//   GET /api/tasks/{id}/changes  changed files with their patches
//   GET /api/tasks/{id}/events   Server-Sent Events: the task's events from
//                                the start (or after Last-Event-ID / ?after=N),
//                                then live ones, plus "state" events
//   GET /api/projects            projects, the most recently used first
//
// Actions (S2), JSON bodies, all through clankctl. Errors are
// {"error": "<message for the user>"} with status 400:
//   POST /api/tasks              {project, prompt} -> {id}
//   POST /api/tasks/{id}/reply   {prompt}
//   POST /api/tasks/{id}/stop
//   POST /api/projects           {name, url}
//
// Who you are (S5): GET /api/me  {login, name, node} from Tailscale
//
// Notifications (S6, push.go):
//   GET  /api/push/key           {key}: the box's VAPID public key
//   POST /api/push/subscribe     a PushSubscription (endpoint, keys)
//   POST /api/push/unsubscribe   {endpoint}
//   POST /api/push/test          {endpoint}: a test notification to that device
//
// Terminals and Claude (S3):
//   GET /api/claude              Claude Code installed / signed in (claude.go)
//   GET /api/terminals           open terminal sessions [{kind, task}]
//   GET /api/terminal/{kind}     WebSocket; kind login or install
//                                (terminal.go has the protocol)

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

func newServer(s *Store, c *Clankctl, ui fs.FS) http.Handler {
	mux := http.NewServeMux()
	claude := &claudeCache{}
	terms := NewTerminals(c, func(kind, task string) {
		s.invalidate()
		claude.invalidate()
	})
	mux.HandleFunc("GET /api/me", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, identityFrom(r.Context()))
	})
	pushOff := func(w http.ResponseWriter) bool {
		if s.Push == nil {
			writeError(w, &ActionError{"Notifications aren't set up on this box."})
			return true
		}
		return false
	}
	mux.HandleFunc("GET /api/push/key", func(w http.ResponseWriter, r *http.Request) {
		if pushOff(w) {
			return
		}
		writeJSON(w, map[string]string{"key": s.Push.PublicKey()})
	})
	mux.HandleFunc("POST /api/push/subscribe", func(w http.ResponseWriter, r *http.Request) {
		var sub webpush.Subscription
		if pushOff(w) || !readJSON(w, r, &sub) {
			return
		}
		if err := s.Push.Subscribe(sub, identityFrom(r.Context())); err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /api/push/unsubscribe", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Endpoint string }
		if pushOff(w) || !readJSON(w, r, &in) {
			return
		}
		if err := s.Push.Unsubscribe(in.Endpoint); err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /api/push/test", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Endpoint string }
		if pushOff(w) || !readJSON(w, r, &in) {
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		n := Notification{Title: "Clankstation", Body: "Notifications work on this device.", URL: "/#/settings", Tag: "test"}
		if err := s.Push.Send(ctx, n, in.Endpoint); err != nil {
			var ae *ActionError
			if !errors.As(err, &ae) {
				err = &ActionError{"The phone's push service didn't take it: " + err.Error()}
			}
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /api/claude", func(w http.ResponseWriter, r *http.Request) {
		st, err := claude.get(r.Context(), c)
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, st)
	})
	mux.HandleFunc("GET /api/terminals", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, terms.List())
	})
	mux.HandleFunc("GET /api/terminal/{kind}", func(w http.ResponseWriter, r *http.Request) {
		kind, task := r.PathValue("kind"), r.URL.Query().Get("task")
		// Check before starting anything: taking over stops a running task.
		if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
			http.Error(w, "expected a WebSocket", http.StatusBadRequest)
			return
		}
		if !sameOrigin(w, r) {
			return
		}
		sess, err := terms.Open(kind, task)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		s.invalidate()
		terms.ServeWS(w, r, sess)
	})
	mux.HandleFunc("GET /api/projects", func(w http.ResponseWriter, r *http.Request) {
		ps := s.Projects()
		for i := range ps {
			ps[i].URL = redactURL(ps[i].URL)
		}
		writeJSON(w, ps)
	})
	mux.HandleFunc("POST /api/projects", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Name, URL string }
		if !readJSON(w, r, &in) {
			return
		}
		err := c.AddProject(r.Context(), in.Name, in.URL)
		s.invalidate()
		if err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusCreated)
	})
	mux.HandleFunc("POST /api/tasks", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Project, Prompt string }
		if !readJSON(w, r, &in) {
			return
		}
		id, err := c.NewTask(r.Context(), in.Project, in.Prompt)
		s.invalidate()
		if err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusCreated)
		writeJSON(w, map[string]string{"id": id})
	})
	mux.HandleFunc("POST /api/tasks/{id}/reply", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Prompt string }
		if _, ok := s.taskDir(r.PathValue("id")); !ok {
			http.NotFound(w, r)
			return
		}
		if !readJSON(w, r, &in) {
			return
		}
		err := c.Reply(r.Context(), r.PathValue("id"), in.Prompt)
		s.invalidate()
		if err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /api/tasks/{id}/stop", func(w http.ResponseWriter, r *http.Request) {
		if _, ok := s.taskDir(r.PathValue("id")); !ok {
			http.NotFound(w, r)
			return
		}
		if !sameOrigin(w, r) {
			return
		}
		err := c.Stop(r.Context(), r.PathValue("id"))
		s.invalidate()
		if err != nil {
			writeError(w, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /api/tasks", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, s.List())
	})
	mux.HandleFunc("GET /api/tasks/{id}", func(w http.ResponseWriter, r *http.Request) {
		d, ok := s.Get(r.PathValue("id"))
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, d)
	})
	mux.HandleFunc("GET /api/tasks/{id}/changes", func(w http.ResponseWriter, r *http.Request) {
		dir, ok := s.taskDir(r.PathValue("id"))
		if !ok {
			http.NotFound(w, r)
			return
		}
		writeJSON(w, parsePatch(filepath.Join(dir, "result", "diff.patch")))
	})
	mux.HandleFunc("GET /api/tasks/{id}/events", func(w http.ResponseWriter, r *http.Request) {
		streamEvents(s, w, r)
	})
	mux.HandleFunc("/api/", http.NotFound)
	mux.Handle("/", spa(ui))
	return securityHeaders(mux)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}

// sameOrigin refuses requests a page on another site could make: a browser
// sends Origin with every POST, and it must name this host. (Not a login:
// that comes with S5. It stops other web pages from driving the box.)
func sameOrigin(w http.ResponseWriter, r *http.Request) bool {
	o := r.Header.Get("Origin")
	if o == "" {
		if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
			http.Error(w, "cross-site request", http.StatusForbidden)
			return false
		}
		return true // not a browser (curl, tests)
	}
	u, err := url.Parse(o)
	if err != nil || u.Host != r.Host {
		http.Error(w, "cross-site request", http.StatusForbidden)
		return false
	}
	return true
}

// readJSON reads a small JSON body from a same-origin request.
func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if !sameOrigin(w, r) {
		return false
	}
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		http.Error(w, "expected application/json", http.StatusUnsupportedMediaType)
		return false
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v); err != nil {
		http.Error(w, "bad JSON", http.StatusBadRequest)
		return false
	}
	return true
}

func writeError(w http.ResponseWriter, err error) {
	var ae *ActionError
	msg := "Something went wrong on the box."
	if errors.As(err, &ae) {
		msg = ae.Msg
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusBadRequest)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

var urlUserinfo = regexp.MustCompile(`://[^/@]*@`)

// redactURL hides credentials someone put in a clone URL.
func redactURL(s string) string { return urlUserinfo.ReplaceAllString(s, "://") }

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "same-origin") // "no-referrer" makes form posts send Origin: null
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'")
		h.ServeHTTP(w, r)
	})
}

// spa serves the built web app; unknown paths get index.html.
func spa(ui fs.FS) http.Handler {
	files := http.FileServerFS(ui)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/")
		if p != "" {
			if _, err := fs.Stat(ui, p); err == nil {
				if strings.HasPrefix(p, "assets/") {
					w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
				}
				files.ServeHTTP(w, r)
				return
			}
		}
		w.Header().Set("Cache-Control", "no-cache")
		http.ServeFileFS(w, r, ui, "index.html")
	})
}

const (
	pollInterval      = 500 * time.Millisecond
	heartbeatInterval = 15 * time.Second
)

func streamEvents(s *Store, w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	dir, ok := s.taskDir(id)
	if !ok {
		http.NotFound(w, r)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	after := 0
	if v := r.Header.Get("Last-Event-ID"); v != "" {
		after, _ = strconv.Atoi(v)
	} else if v := r.URL.Query().Get("after"); v != "" {
		after, _ = strconv.Atoi(v)
	}

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no")

	tail := &lineTail{path: filepath.Join(dir, "events.jsonl")}
	lastState := ""
	sendState := func() {
		d := s.summary(id, dir, s.running()[id])
		if d.State != lastState {
			lastState = d.State
			b, _ := json.Marshal(Event{V: ProtocolVersion, Type: "state", State: d.State})
			fmt.Fprintf(w, "data: %s\n\n", b)
		}
	}
	sendEvents := func() {
		for _, l := range tail.next() {
			if l.seq <= after {
				continue
			}
			for _, e := range Translate(l.seq, l.text) {
				b, _ := json.Marshal(e)
				fmt.Fprintf(w, "id: %d\ndata: %s\n\n", e.Seq, b)
			}
			// Lines that translate to nothing still move the resume point.
			after = l.seq
		}
	}

	sendState()
	sendEvents()
	fmt.Fprint(w, "retry: 3000\n\n")
	flusher.Flush()

	tick := time.NewTicker(pollInterval)
	defer tick.Stop()
	beat := time.NewTicker(heartbeatInterval)
	defer beat.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-beat.C:
			fmt.Fprint(w, ": keep-alive\n\n")
			flusher.Flush()
		case <-tick.C:
			sendEvents()
			sendState()
			flusher.Flush()
		}
	}
}

type line struct {
	seq  int
	text []byte
}

// lineTail reads complete new lines from an append-only file.
type lineTail struct {
	path   string
	offset int64
	seq    int
}

func (t *lineTail) next() []line {
	f, err := os.Open(t.path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if _, err := f.Seek(t.offset, io.SeekStart); err != nil {
		return nil
	}
	b, err := io.ReadAll(io.LimitReader(f, 32<<20))
	if err != nil || len(b) == 0 {
		return nil
	}
	end := strings.LastIndexByte(string(b), '\n')
	if end < 0 {
		return nil // only a partial line so far
	}
	var out []line
	for _, l := range strings.Split(string(b[:end]), "\n") {
		t.seq++
		out = append(out, line{seq: t.seq, text: []byte(l)})
	}
	t.offset += int64(end + 1)
	return out
}

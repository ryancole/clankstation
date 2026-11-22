package main

// HTTP API, protocol v1:
//   GET /api/tasks               task cards for Home
//   GET /api/tasks/{id}          one task: state, summary, turns, changed files
//   GET /api/tasks/{id}/changes  changed files with their patches
//   GET /api/tasks/{id}/events   Server-Sent Events: the task's events from
//                                the start (or after Last-Event-ID / ?after=N),
//                                then live ones, plus "state" events

import (
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func newServer(s *Store, ui fs.FS) http.Handler {
	mux := http.NewServeMux()
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

func securityHeaders(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
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

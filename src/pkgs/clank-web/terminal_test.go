package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/coder/websocket"
)

func TestParseHarnessStatus(t *testing.T) {
	st := parseHarnessStatus("claude: 2.1.330 (Claude Code)\n{\n \"loggedIn\": true,\n \"authMethod\": \"claude.ai\",\n \"email\": \"x@example.com\",\n \"subscriptionType\": \"max\"\n}\n")
	if !st.Installed || st.Version != "2.1.330" || !st.SignedIn || st.Method != "claude.ai" || st.Plan != "max" {
		t.Errorf("status = %+v", st)
	}
	b, _ := json.Marshal(st)
	if strings.Contains(string(b), "example.com") {
		t.Errorf("email leaked: %s", b)
	}
	if st := parseHarnessStatus("claude: not installed (run: clankctl harness enable claude)\n"); st.Installed {
		t.Errorf("not installed = %+v", st)
	}
	if st := parseHarnessStatus("claude: 2.1.0 (Claude Code)\n{\"loggedIn\": false}\n"); !st.Installed || st.SignedIn {
		t.Errorf("signed out = %+v", st)
	}
}

// A fake clankctl whose "login" is an echo loop on a terminal, and whose
// "attach" quits on /exit, like Claude Code.
func termClankctl(t *testing.T) *Clankctl {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "clankctl")
	write(t, script, `#!/bin/sh
case "$1" in
  login)
    [ -t 0 ] && echo "on a terminal: $TERM"
    while IFS= read -r line; do echo "got: $line"; done ;;
  attach)
    echo "taking over $3"
    while IFS= read -r line; do
      case "$line" in *"/exit"*) echo "bye"; exit 0 ;; esac
    done ;;
esac
`)
	must(t, os.Chmod(script, 0o755))
	return &Clankctl{Path: script, User: "default"}
}

func TestTerminal(t *testing.T) {
	root := t.TempDir()
	fakeTask(t, root, "t-20261121-120000-aaaa", "done")
	s := &Store{Data: root}
	srv := httptest.NewServer(newServer(s, termClankctl(t), fstest.MapFS{"index.html": {Data: []byte("x")}}))
	defer srv.Close()
	ws := "ws" + strings.TrimPrefix(srv.URL, "http")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	readUntil := func(c *websocket.Conn, want string) string {
		t.Helper()
		var got strings.Builder
		for !strings.Contains(got.String(), want) {
			typ, b, err := c.Read(ctx)
			if err != nil {
				t.Fatalf("waiting for %q, got %q: %v", want, got.String(), err)
			}
			if typ == websocket.MessageBinary {
				got.Write(b)
			} else {
				got.WriteString("<control " + string(b) + ">")
			}
		}
		return got.String()
	}

	// Another site's page can't open one.
	_, resp, err := websocket.Dial(ctx, ws+"/api/terminal/login", &websocket.DialOptions{
		HTTPHeader: http.Header{"Origin": {"http://evil.example"}}})
	if err == nil || resp == nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-origin terminal: %v %v", err, resp)
	}

	c, _, err := websocket.Dial(ctx, ws+"/api/terminal/login", nil)
	must(t, err)
	readUntil(c, "on a terminal: xterm-256color")
	must(t, c.Write(ctx, websocket.MessageText, []byte(`{"type":"resize","cols":120,"rows":40}`)))
	must(t, c.Write(ctx, websocket.MessageBinary, []byte("hello\r")))
	readUntil(c, "got: hello")

	// A second page takes over and sees the screen so far.
	c2, _, err := websocket.Dial(ctx, ws+"/api/terminal/login", nil)
	must(t, err)
	readUntil(c2, "got: hello")
	if _, _, err := c.Read(ctx); err == nil {
		t.Error("first page still connected")
	}
	resp2, _ := http.Get(srv.URL + "/api/terminals")
	var list []TermInfo
	must(t, json.NewDecoder(resp2.Body).Decode(&list))
	if len(list) != 1 || list[0].Kind != "login" {
		t.Errorf("terminals = %+v", list)
	}
	// "end" sends Ctrl-C: the session exits and the page is told.
	must(t, c2.Write(ctx, websocket.MessageText, []byte(`{"type":"end"}`)))
	readUntil(c2, `<control {"type":"exit"`)

	// Take over a task; hand back ends it with /exit.
	a, _, err := websocket.Dial(ctx, ws+"/api/terminal/attach?task=t-20261121-120000-aaaa", nil)
	must(t, err)
	readUntil(a, "taking over t-20261121-120000-aaaa")
	r, _ := http.Get(srv.URL + "/api/tasks/t-20261121-120000-aaaa")
	var d TaskDetail
	must(t, json.NewDecoder(r.Body).Decode(&d))
	if !d.Terminal {
		t.Error("task detail doesn't show the open terminal")
	}
	must(t, a.Write(ctx, websocket.MessageText, []byte(`{"type":"end"}`)))
	out := readUntil(a, `<control {"type":"exit","code":0}>`)
	if !strings.Contains(out, "bye") {
		t.Errorf("attach ended without /exit: %q", out)
	}
	if _, _, err := websocket.Dial(ctx, ws+"/api/terminal/attach?task=t-20990101-000000-ffff", nil); err == nil {
		t.Error("attach to an unknown task accepted")
	}
	if _, _, err := websocket.Dial(ctx, ws+"/api/terminal/shell", nil); err == nil {
		t.Error("unknown terminal kind accepted")
	}
}

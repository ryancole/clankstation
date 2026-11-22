package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

const sampleEvents = `{"type":"system","subtype":"init","session_id":"s-1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Let me look."},{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"/workspace/src/contact.py"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","is_error":false,"content":"..."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu2","name":"TodoWrite","input":{"todos":[{"content":"Find the form","status":"completed"},{"content":"Send mail","status":"in_progress"}]}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu3","name":"Bash","input":{"command":"pytest -q","description":"Run the tests"}}]}}
not json
{"type":"result","subtype":"success","is_error":false,"result":"Done.\n\nShould it go to info@?","total_cost_usd":0.12,"duration_ms":4000}
`

const samplePatch = `diff --git a/contact.py b/contact.py
index 1111111..2222222 100644
--- a/contact.py
+++ b/contact.py
@@ -1,3 +1,4 @@
 def contact(form):
-    log(form)
+    send_mail(form)
+    return page()
diff --git a/mailer.py b/mailer.py
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/mailer.py
@@ -0,0 +1,2 @@
+def send_mail(form):
+    pass
`

func fakeTask(t *testing.T, root, id, status string) string {
	t.Helper()
	d := filepath.Join(root, "tasks", id)
	must(t, os.MkdirAll(filepath.Join(d, "result"), 0o755))
	write(t, filepath.Join(d, "task.env"), "project=bakery\nbranch=main\nbase=abc\ncreated=2026-11-21T12:00:00Z\nuser=admin\nenv=linux-default\n")
	write(t, filepath.Join(d, "prompts.log"), "--- 2026-11-21T12:00:00Z run\nMake the contact form send an email\nto us.\n--- 2026-11-21T12:10:00Z resume\nkeep going\n")
	write(t, filepath.Join(d, "events.jsonl"), sampleEvents)
	write(t, filepath.Join(d, "result", "summary.md"), "Done.\n\nShould it go to info@?\n")
	write(t, filepath.Join(d, "result", "diff.patch"), samplePatch)
	if status != "" {
		write(t, filepath.Join(d, "status.json"), `{"state":"`+status+`","mode":"headless","exit_code":0,"session_id":"s-1","started":"a","finished":"2026-11-21T12:20:00Z"}`)
	}
	return d
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
func write(t *testing.T, p, s string) { t.Helper(); must(t, os.WriteFile(p, []byte(s), 0o644)) }

func TestTranslate(t *testing.T) {
	var got []Event
	for i, l := range strings.Split(sampleEvents, "\n") {
		got = append(got, Translate(i+1, []byte(l))...)
	}
	want := []struct{ typ, label string }{
		{"turn", ""}, {"message", ""}, {"step", "Looking at src/contact.py"},
		{"step_result", ""}, {"plan", ""}, {"step", "Run the tests"}, {"result", ""},
	}
	if len(got) != len(want) {
		t.Fatalf("got %d events: %+v", len(got), got)
	}
	for i, w := range want {
		if got[i].Type != w.typ || got[i].Label != w.label || got[i].V != 1 {
			t.Errorf("event %d = %+v, want %s %q", i, got[i], w.typ, w.label)
		}
	}
	if got[1].Seq != 2 || got[2].Seq != 2 {
		t.Errorf("events from line 2 should share seq 2: %+v", got[1:3])
	}
	if p := got[4].Items; len(p) != 2 || p[1].Status != "in_progress" {
		t.Errorf("plan = %+v", p)
	}
	if got[6].CostUSD != 0.12 || got[6].Summary == "" {
		t.Errorf("result = %+v", got[6])
	}
}

func TestTrailingQuestion(t *testing.T) {
	for in, want := range map[string]bool{
		"Done.\n\nShould it go to info@?":                                true,
		"Done.\n\nDo you want a fourth fact? If so, I could add one.":    true,
		"Done.\n\n**Want me to commit it?**":                             true,
		"Is it fixed? Yes.\n\nAll tests pass.":                           false,
		"Done.\n\nSee https://example.com/a?b=1 and `x?.y` for details.": false,
		"": false,
	} {
		if got := trailingQuestion(in) != ""; got != want {
			t.Errorf("trailingQuestion(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestStore(t *testing.T) {
	root := t.TempDir()
	fakeTask(t, root, "t-20261121-120000-aaaa", "done")
	fakeTask(t, root, "t-20261121-130000-bbbb", "")
	fakeTask(t, root, "t-20261121-140000-cccc", "failed")
	must(t, os.MkdirAll(filepath.Join(root, "tasks", "not-a-task"), 0o755))
	running := "t-20261121-130000-bbbb"
	s := &Store{Data: root, Running: func() (map[string]bool, error) { return map[string]bool{running: true}, nil }}

	list := s.List()
	if len(list) != 3 || list[0].ID != "t-20261121-140000-cccc" {
		t.Fatalf("list = %+v", list)
	}
	states := map[string]string{}
	for _, x := range list {
		states[x.ID] = x.State
	}
	if states["t-20261121-120000-aaaa"] != StateNeedsInput ||
		states["t-20261121-130000-bbbb"] != StateRunning ||
		states["t-20261121-140000-cccc"] != StateFailed {
		t.Errorf("states = %v", states)
	}
	if list[1].Activity != "Run the tests" {
		t.Errorf("running activity = %q", list[1].Activity)
	}

	d, ok := s.Get("t-20261121-120000-aaaa")
	if !ok || d.Title != "Make the contact form send an email" || len(d.Turns) != 2 ||
		d.Turns[0].Prompt != "Make the contact form send an email\nto us." || d.Question != "Should it go to info@?" {
		t.Fatalf("detail = %+v", d)
	}
	if len(d.Files) != 2 || d.Files[0].Added != 2 || d.Files[0].Removed != 1 ||
		d.Files[1].Status != "added" || d.Files[1].Path != "mailer.py" || d.Files[0].Patch != "" {
		t.Errorf("files = %+v", d.Files)
	}

	// Lost: no container, no status.json. Interactive: running after attach.
	running = ""
	if got := s.summary("t-20261121-130000-bbbb", filepath.Join(root, "tasks", "t-20261121-130000-bbbb"), false).State; got != StateLost {
		t.Errorf("lost state = %s", got)
	}
	dir := filepath.Join(root, "tasks", "t-20261121-130000-bbbb")
	f, _ := os.OpenFile(filepath.Join(dir, "prompts.log"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString("--- 2026-11-21T12:30:00Z attach\n")
	f.Close()
	if got := s.summary("t-20261121-130000-bbbb", dir, true).State; got != StateInteractive {
		t.Errorf("interactive state = %s", got)
	}
	if _, ok := s.Get("../etc"); ok {
		t.Error("path traversal accepted")
	}

	// Waiting in line, in the order clankctl's queued files say.
	q1 := fakeTask(t, root, "t-20261121-150000-dddd", "")
	q2 := fakeTask(t, root, "t-20261121-140500-eeee", "")
	write(t, filepath.Join(q1, "queued"), "2026-11-21T15:00:00.000000001Z\n")
	write(t, filepath.Join(q2, "queued"), "2026-11-21T15:00:00.000000002Z\n")
	for id, want := range map[string]string{
		"t-20261121-150000-dddd": "Next in line",
		"t-20261121-140500-eeee": "2nd in line",
	} {
		d, _ := s.Get(id)
		if d.State != StateQueued || d.Activity != want {
			t.Errorf("%s: %s %q, want queued %q", id, d.State, d.Activity, want)
		}
	}
	for n, want := range map[int]string{1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 11: "11th", 12: "12th", 13: "13th", 21: "21st", 22: "22nd", 101: "101st"} {
		if got := ordinal(n); got != want {
			t.Errorf("ordinal(%d) = %s, want %s", n, got, want)
		}
	}
}

func TestEventsStream(t *testing.T) {
	root := t.TempDir()
	dir := fakeTask(t, root, "t-20261121-120000-aaaa", "")
	s := &Store{Data: root, Running: func() (map[string]bool, error) {
		return map[string]bool{"t-20261121-120000-aaaa": true}, nil
	}}
	ui := fstest.MapFS{"index.html": {Data: []byte("<!doctype html>app")}}
	srv := httptest.NewServer(newServer(s, &Clankctl{Path: "false", User: "default"}, ui))
	defer srv.Close()

	req, _ := http.NewRequest("GET", srv.URL+"/api/tasks/t-20261121-120000-aaaa/events", nil)
	req.Header.Set("Last-Event-ID", "4")
	resp, err := http.DefaultClient.Do(req)
	must(t, err)
	defer resp.Body.Close()
	sc := bufio.NewScanner(resp.Body)
	read := func(want string) {
		t.Helper()
		deadline := time.After(5 * time.Second)
		lines := make(chan string)
		go func() {
			for sc.Scan() {
				lines <- sc.Text()
				if strings.Contains(sc.Text(), want) {
					return
				}
			}
			close(lines)
		}()
		for {
			select {
			case l, ok := <-lines:
				if !ok {
					t.Fatalf("stream ended before %q", want)
				}
				if strings.HasPrefix(l, "data: ") && strings.Contains(l, `"type":"turn"`) {
					t.Fatalf("got an event at or before Last-Event-ID: %s", l)
				}
				if strings.Contains(l, want) {
					return
				}
			case <-deadline:
				t.Fatalf("timed out waiting for %q", want)
			}
		}
	}
	read(`"state":"running"`)
	read(`"label":"Run the tests"`)
	read(`"type":"result"`)

	// A line appended later arrives live, with the next seq.
	f, _ := os.OpenFile(filepath.Join(dir, "events.jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"type":"assistant","message":{"content":[{"type":"text","text":"later"}]}}` + "\n")
	f.Close()
	read(`"seq":8,"type":"message","text":"later"`)

	// The SPA falls back to index.html; unknown API paths are 404.
	r2, _ := http.Get(srv.URL + "/task/whatever")
	if r2.StatusCode != 200 {
		t.Errorf("spa fallback status %d", r2.StatusCode)
	}
	r3, _ := http.Get(srv.URL + "/api/nope")
	if r3.StatusCode != 404 {
		t.Errorf("unknown api status %d", r3.StatusCode)
	}
}

// A fake clankctl that logs its arguments, CLANK_USER and stdin.
func fakeClankctl(t *testing.T) (*Clankctl, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	script := filepath.Join(dir, "clankctl")
	write(t, script, `#!/bin/sh
{ echo "user=$CLANK_USER args=$*"; [ "$2" = - ] || [ "$3" = - ] && cat; echo; } >> `+log+`
case "$1 $2" in
  "run demo") echo t-20261122-010203-abcd ;;
  "run nope") echo "clankctl: no such project: nope (see: clankctl project list)" >&2; exit 1 ;;
esac
`)
	must(t, os.Chmod(script, 0o755))
	return &Clankctl{Path: script, User: "default"}, log
}

func TestActions(t *testing.T) {
	root := t.TempDir()
	fakeTask(t, root, "t-20261121-120000-aaaa", "done")
	must(t, os.MkdirAll(filepath.Join(root, "projects", "bakery"), 0o755))
	write(t, filepath.Join(root, "projects", "bakery", "project.env"), "url=https://bob:secret@example.com/b.git\ntemplate=auto\n")
	must(t, os.MkdirAll(filepath.Join(root, "projects", "alpha"), 0o755))
	write(t, filepath.Join(root, "projects", "alpha", "project.env"), "url=https://example.com/a.git\ntemplate=auto\n")
	c, log := fakeClankctl(t)
	s := &Store{Data: root}
	srv := httptest.NewServer(newServer(s, c, fstest.MapFS{"index.html": {Data: []byte("x")}}))
	defer srv.Close()

	post := func(path, body string, hdr ...string) (*http.Response, string) {
		t.Helper()
		req, _ := http.NewRequest("POST", srv.URL+path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
		resp, err := http.DefaultClient.Do(req)
		must(t, err)
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp, string(b)
	}

	// Projects: bakery has a task, so it comes first; credentials are hidden.
	resp, _ := http.Get(srv.URL + "/api/projects")
	var ps []Project
	must(t, json.NewDecoder(resp.Body).Decode(&ps))
	if len(ps) != 2 || ps[0].Name != "bakery" || ps[0].URL != "https://example.com/b.git" || ps[1].Name != "alpha" {
		t.Errorf("projects = %+v", ps)
	}

	r, body := post("/api/tasks", `{"project":"demo","prompt":"-rf\n'quoted' $HOME"}`, "Origin", srv.URL)
	if r.StatusCode != 201 || !strings.Contains(body, `"id":"t-20261122-010203-abcd"`) {
		t.Errorf("new task: %d %s", r.StatusCode, body)
	}
	r, body = post("/api/tasks", `{"project":"nope","prompt":"x"}`)
	if r.StatusCode != 400 || !strings.Contains(body, "no such project: nope") {
		t.Errorf("bad project: %d %s", r.StatusCode, body)
	}
	if r, _ = post("/api/tasks", `{"project":"demo","prompt":"  "}`); r.StatusCode != 400 {
		t.Errorf("empty prompt: %d", r.StatusCode)
	}
	if r, _ = post("/api/tasks/t-20261121-120000-aaaa/reply", `{"prompt":"go on"}`); r.StatusCode != 204 {
		t.Errorf("reply: %d", r.StatusCode)
	}
	if r, _ = post("/api/tasks/t-20261121-120000-aaaa/stop", ``); r.StatusCode != 204 {
		t.Errorf("stop: %d", r.StatusCode)
	}
	if r, _ = post("/api/tasks/t-20990101-000000-ffff/reply", `{"prompt":"x"}`); r.StatusCode != 404 {
		t.Errorf("reply to unknown task: %d", r.StatusCode)
	}
	if r, _ = post("/api/projects", `{"name":"New","url":"x"}`); r.StatusCode != 400 {
		t.Errorf("bad project name: %d", r.StatusCode)
	}
	if r, _ = post("/api/projects", `{"name":"new","url":"--upload-pack=x"}`); r.StatusCode != 400 {
		t.Errorf("option as url: %d", r.StatusCode)
	}
	if r, _ = post("/api/projects", `{"name":"new","url":"https://example.com/n.git"}`); r.StatusCode != 201 {
		t.Errorf("add project: %d", r.StatusCode)
	}

	// Other sites can't drive the box.
	if r, _ = post("/api/tasks", `{"project":"demo","prompt":"x"}`, "Origin", "http://evil.example"); r.StatusCode != 403 {
		t.Errorf("cross-origin: %d", r.StatusCode)
	}
	if r, _ = post("/api/tasks/t-20261121-120000-aaaa/stop", ``, "Sec-Fetch-Site", "cross-site"); r.StatusCode != 403 {
		t.Errorf("cross-site stop: %d", r.StatusCode)
	}

	b, _ := os.ReadFile(log)
	got := string(b)
	for _, want := range []string{
		"user=default args=run demo -\n-rf\n'quoted' $HOME\n",
		"args=resume t-20261121-120000-aaaa -\ngo on\n",
		"args=stop t-20261121-120000-aaaa\n",
		"args=project add new https://example.com/n.git\n",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("clankctl log lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "evil") || strings.Contains(got, "upload-pack") || strings.Contains(got, "New") {
		t.Errorf("refused requests reached clankctl:\n%s", got)
	}
}

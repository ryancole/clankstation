package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseGitHubStatus(t *testing.T) {
	signedIn := `{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"alice","tokenSource":"/home/agent/.config/gh/hosts.yml"}]}}`
	if st := parseGitHubStatus(signedIn); !st.SignedIn || st.Login != "alice" {
		t.Fatalf("signed in: %+v", st)
	}
	for _, out := range []string{`{"hosts":{}}`, ``, `{"hosts":{"github.com":[{"state":"error","active":true,"login":"alice"}]}}`} {
		if st := parseGitHubStatus(out); st.SignedIn {
			t.Fatalf("%q: %+v", out, st)
		}
	}
}

func TestReadPullRequest(t *testing.T) {
	d := t.TempDir()
	if readPullRequest(d) != nil {
		t.Fatal("no pr.json: no pull request")
	}
	must(t, os.MkdirAll(filepath.Join(d, "result"), 0o755))
	for json, want := range map[string]PullRequest{
		`{"number":3,"url":"u","state":"OPEN","isDraft":true,"branch":"clank/x-1234"}`: {Number: 3, URL: "u", State: "draft", Branch: "clank/x-1234"},
		`{"number":3,"state":"OPEN","isDraft":false}`:                                  {Number: 3, State: "open"},
		`{"number":3,"state":"MERGED","isDraft":false}`:                                {Number: 3, State: "merged"},
		`{"number":3,"state":"CLOSED","isDraft":true}`:                                 {Number: 3, State: "closed"},
		`{"error":"Sign in to GitHub in Settings to open pull requests."}`:             {Error: "Sign in to GitHub in Settings to open pull requests."},
	} {
		write(t, filepath.Join(d, "result", "pr.json"), json)
		if got := readPullRequest(d); got == nil || *got != want {
			t.Errorf("%s: %+v", json, got)
		}
	}
}

func TestProjectPullRequests(t *testing.T) {
	root := t.TempDir()
	for name, env := range map[string]string{
		"gh":      "url=https://github.com/a/b\ntemplate=auto\n",
		"gh-off":  "url=git@github.com:a/b.git\ntemplate=auto\npull_requests=off\n",
		"other":   "url=https://gitlab.com/a/b\ntemplate=auto\n",
		"otheron": "url=git://example/b\ntemplate=auto\npull_requests=on\n",
	} {
		must(t, os.MkdirAll(filepath.Join(root, "projects", name), 0o755))
		write(t, filepath.Join(root, "projects", name, "project.env"), env)
	}
	got := map[string]Project{}
	for _, p := range (&Store{Data: root}).Projects() {
		got[p.Name] = p
	}
	if !got["gh"].GitHub || !got["gh"].PullRequests || !got["gh-off"].GitHub || got["gh-off"].PullRequests ||
		got["other"].GitHub || got["other"].PullRequests || !got["otheron"].PullRequests {
		t.Fatalf("%+v", got)
	}
}

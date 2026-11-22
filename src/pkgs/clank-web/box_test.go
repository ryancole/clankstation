package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

// testBox is a box in a temp dir: a fake nixos-version and systems whose
// kernels can differ.
func testBox(t *testing.T) (*Box, string) {
	t.Helper()
	root := t.TempDir()
	b := NewBox(filepath.Join(root, "data"))
	b.UpdateEnv = filepath.Join(root, "update.env")
	b.RunDir = filepath.Join(root, "run")
	b.System = filepath.Join(root, "current")
	b.Booted = filepath.Join(root, "booted")
	b.NixosVersion = filepath.Join(root, "nixos-version")
	must(t, os.MkdirAll(filepath.Join(b.Data, "settings"), 0o755))
	must(t, os.MkdirAll(filepath.Join(b.Data, "update"), 0o755))
	write(t, b.UpdateEnv, "flake=github:x/y\nconfiguration=clankstation\n")
	write(t, b.NixosVersion, "#!/bin/sh\necho '{\"nixosVersion\":\"26.05.1\",\"configurationRevision\":\"rev-1\"}'\n")
	must(t, os.Chmod(b.NixosVersion, 0o755))
	for _, sys := range []string{"sys-a", "sys-b"} {
		must(t, os.MkdirAll(filepath.Join(root, sys), 0o755))
		write(t, filepath.Join(root, sys+"-kernel"), sys)
		must(t, os.Symlink(filepath.Join(root, sys+"-kernel"), filepath.Join(root, sys, "kernel")))
	}
	must(t, os.Symlink(filepath.Join(root, "sys-a"), b.System))
	must(t, os.Symlink(filepath.Join(root, "sys-a"), b.Booted))
	return b, root
}

func TestBoxStatus(t *testing.T) {
	b, root := testBox(t)
	st := b.Status()
	if st.Version != (VersionInfo{"26.05.1", "rev-1"}) || !st.Updates || st.Busy != "" || st.RestartNeeded {
		t.Fatalf("fresh box: %+v", st)
	}
	if st.Check != nil || st.Update != nil || len(st.Disks) == 0 || st.Disks[0].Size == 0 {
		t.Fatalf("fresh box: %+v", st)
	}

	// A check that found a newer version.
	up := filepath.Join(b.Data, "update")
	write(t, filepath.Join(up, "check.json"), `{"started":"a","finished":"b","exit":0}`)
	write(t, filepath.Join(up, "check.log"), "Installed: rev-1 (clankstation)\nLatest:    rev-2 (github:x/y)\n")
	if c := b.Status().Check; c == nil || !c.OK || c.Latest != "rev-2" || c.UpToDate {
		t.Fatalf("check: %+v", c)
	}
	// A check that couldn't reach GitHub.
	write(t, filepath.Join(up, "check.json"), `{"started":"a","finished":"b","exit":1}`)
	write(t, filepath.Join(up, "check.log"), "clankctl: could not reach github:x/y\n")
	if c := b.Status().Check; c.OK || !strings.Contains(c.Message, "could not reach github:x/y") {
		t.Fatalf("failed check: %+v", c)
	}

	// Asking: a request file, then busy until the service is done.
	must(t, b.Request("update"))
	if got, _ := os.ReadFile(filepath.Join(b.Data, "settings", "update-request")); string(got) != "update\n" {
		t.Fatalf("request: %q", got)
	}
	if b.Status().Busy != "update" || b.Request("check") == nil {
		t.Fatal("a second request while one is pending")
	}
	// The service picked it up and is running.
	must(t, os.Remove(b.requestFile()))
	must(t, os.MkdirAll(b.RunDir, 0o755))
	write(t, filepath.Join(b.RunDir, "action"), "update\n")
	write(t, filepath.Join(up, "update.json"), `{"started":"a"}`)
	if st := b.Status(); st.Busy != "update" || st.Update == nil || st.Update.Interrupted || st.Update.Finished != "" {
		t.Fatalf("running: %+v %+v", st, st.Update)
	}
	// Finished: a new system with a new kernel and revision.
	must(t, os.RemoveAll(b.RunDir))
	write(t, filepath.Join(up, "update.json"), `{"started":"a","finished":"b","exit":0}`)
	write(t, filepath.Join(up, "update.log"), "Installed: rev-1\nLatest:    rev-2\nbuilding...\nNow at: rev-2\n")
	write(t, filepath.Join(up, "check.json"), `{"started":"a","finished":"b","exit":0}`)
	write(t, filepath.Join(up, "check.log"), "Installed: rev-1 (clankstation)\nLatest:    rev-2 (github:x/y)\n")
	write(t, b.NixosVersion, "#!/bin/sh\necho '{\"nixosVersion\":\"26.05.2\",\"configurationRevision\":\"rev-2\"}'\n")
	must(t, os.Remove(b.System))
	must(t, os.Symlink(filepath.Join(root, "sys-b"), b.System))
	st = b.Status()
	if st.Busy != "" || !st.Update.OK || st.Update.Message != "Updated." || !strings.Contains(st.Update.Log, "Now at: rev-2") {
		t.Fatalf("updated: %+v", st.Update)
	}
	if st.Version.Revision != "rev-2" || !st.RestartNeeded || !st.Check.UpToDate {
		t.Fatalf("after update: %+v %+v", st, st.Check)
	}

	// Started but never finished, and nothing running: interrupted.
	write(t, filepath.Join(up, "update.json"), `{"started":"a"}`)
	if u := b.Status().Update; !u.Interrupted || u.OK {
		t.Fatalf("interrupted: %+v", u)
	}
	// A failed rebuild says why.
	write(t, filepath.Join(up, "update.json"), `{"started":"a","finished":"b","exit":1}`)
	write(t, filepath.Join(up, "update.log"), "building...\nerror: builder for foo failed\n")
	if u := b.Status().Update; u.OK || !strings.Contains(u.Message, "error: builder for foo failed") {
		t.Fatalf("failed: %+v", u)
	}

	// Updates off (the dev VM).
	write(t, b.UpdateEnv, "flake=github:x/y\nconfiguration=\n")
	if b.Status().Updates || b.Request("update") == nil {
		t.Fatal("updates off")
	}
}

func TestBoxAPI(t *testing.T) {
	b, _ := testBox(t)
	s := &Store{Data: b.Data, Running: func() (map[string]bool, error) { return nil, nil }, Box: b}
	srv := httptest.NewServer(newServer(s, &Clankctl{Path: "false"}, fstest.MapFS{}))
	defer srv.Close()

	res, err := http.Get(srv.URL + "/api/box")
	must(t, err)
	var st BoxStatus
	must(t, json.NewDecoder(res.Body).Decode(&st))
	res.Body.Close()
	if st.Version.Revision != "rev-1" || !st.Updates {
		t.Fatalf("GET /api/box: %+v", st)
	}

	// Other sites can't update the box.
	req, _ := http.NewRequest("POST", srv.URL+"/api/box/update", nil)
	req.Header.Set("Origin", "https://evil.example")
	res, err = http.DefaultClient.Do(req)
	must(t, err)
	res.Body.Close()
	if res.StatusCode != http.StatusForbidden {
		t.Fatalf("cross-site update: %d", res.StatusCode)
	}
	if _, err := os.Stat(b.requestFile()); err == nil {
		t.Fatal("cross-site update wrote a request")
	}

	res, err = http.Post(srv.URL+"/api/box/check", "application/json", nil)
	must(t, err)
	res.Body.Close()
	if res.StatusCode != http.StatusAccepted {
		t.Fatalf("check: %d", res.StatusCode)
	}
	if got, _ := os.ReadFile(b.requestFile()); string(got) != "check\n" {
		t.Fatalf("request: %q", got)
	}
	res, err = http.Post(srv.URL+"/api/box/update", "application/json", nil)
	must(t, err)
	res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("update while checking: %d", res.StatusCode)
	}
}

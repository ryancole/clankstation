package main

// The box (S7): its version, updates and free space, for Settings.
//
// clank-web can't update the box itself (it runs unprivileged), so it asks:
// it writes "check" or "update" to settings/update-request, and a root
// service (src/modules/update.nix) runs `clankctl update [--check]`, writing
// update/<action>.json ({started, finished, exit}) and update/<action>.log.
// /run/clankstation-update exists while that service runs. The rebuild may
// restart clank-web; the result is read back from those files afterwards.
//
//   GET  /api/box          Box
//   POST /api/box/check    ask GitHub for the latest version (202)
//   POST /api/box/update   update the box (202)

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Box struct {
	Data         string // /var/lib/clankstation
	UpdateEnv    string // /etc/clankstation/update.env
	RunDir       string // /run/clankstation-update
	System       string // /run/current-system
	Booted       string // /run/booted-system
	NixosVersion string // nixos-version executable

	mu      sync.Mutex
	verFor  string
	version VersionInfo
}

func NewBox(data string) *Box {
	return &Box{
		Data:         data,
		UpdateEnv:    "/etc/clankstation/update.env",
		RunDir:       "/run/clankstation-update",
		System:       "/run/current-system",
		Booted:       "/run/booted-system",
		NixosVersion: "/run/current-system/sw/bin/nixos-version",
	}
}

type VersionInfo struct {
	NixOS    string `json:"nixos"`              // 26.05.20261115.ab5c18f
	Revision string `json:"revision,omitempty"` // Clankstation's git commit
}

type BoxStatus struct {
	Version VersionInfo `json:"version"`
	// Updates is false where `clankctl update` is off (the dev VM).
	Updates bool `json:"updates"`
	// Busy is "check" or "update" while one is asked for or running.
	Busy          string        `json:"busy,omitempty"`
	Check         *CheckResult  `json:"check,omitempty"`
	Update        *UpdateResult `json:"update,omitempty"`
	RestartNeeded bool          `json:"restart_needed"`
	Disks         []Disk        `json:"disks"`
}

type CheckResult struct {
	Finished string `json:"finished,omitempty"`
	OK       bool   `json:"ok"`
	Latest   string `json:"latest,omitempty"`
	UpToDate bool   `json:"up_to_date"`
	Message  string `json:"message,omitempty"`
}

type UpdateResult struct {
	Started  string `json:"started"`
	Finished string `json:"finished,omitempty"`
	OK       bool   `json:"ok"`
	// Interrupted: it started but never finished (the box restarted).
	Interrupted bool   `json:"interrupted,omitempty"`
	Message     string `json:"message,omitempty"`
	Log         string `json:"log,omitempty"` // the last lines of its output
}

type Disk struct {
	Name string `json:"name"`
	Free uint64 `json:"free"`
	Size uint64 `json:"size"`
}

func (b *Box) Status() *BoxStatus {
	st := &BoxStatus{
		Version:       b.Version(),
		Updates:       b.updatesOn(),
		Busy:          b.busy(),
		RestartNeeded: b.restartNeeded(),
		Disks:         []Disk{},
	}
	for _, d := range []struct{ name, path string }{
		{"Tasks and projects", b.Data},
		{"System", "/nix/store"},
	} {
		var fs syscall.Statfs_t
		if syscall.Statfs(d.path, &fs) == nil {
			st.Disks = append(st.Disks, Disk{d.name, fs.Bavail * uint64(fs.Bsize), fs.Blocks * uint64(fs.Bsize)})
		}
	}
	if r, log, ok := b.result("check"); ok && r.Finished != "" && st.Busy != "check" {
		c := &CheckResult{Finished: r.Finished, OK: r.Exit == 0}
		for _, l := range log {
			if v, ok := strings.CutPrefix(l, "Latest:"); ok {
				c.Latest = firstField(v)
			}
		}
		if c.OK {
			c.UpToDate = c.Latest != "" && c.Latest == st.Version.Revision
		} else {
			c.Message = failure(log, "The box couldn't check for updates.")
		}
		st.Check = c
	}
	if r, log, ok := b.result("update"); ok {
		u := &UpdateResult{Started: r.Started, Finished: r.Finished, OK: r.Finished != "" && r.Exit == 0}
		switch {
		case r.Finished == "" && st.Busy != "update":
			u.Interrupted = true
			u.Message = "The last update didn't finish. The box may have restarted during it."
		case r.Finished == "":
		case u.OK && contains(log, "Up to date."):
			u.Message = "It was already up to date."
		case u.OK:
			u.Message = "Updated."
		default:
			u.Message = failure(log, "The update didn't work.")
		}
		if len(log) > 40 {
			log = log[len(log)-40:]
		}
		u.Log = strings.Join(log, "\n")
		st.Update = u
	}
	return st
}

// Request asks the root service for a check or an update.
func (b *Box) Request(action string) error {
	if !b.updatesOn() {
		return &ActionError{"Updates are off on this box."}
	}
	if b.busy() != "" {
		return &ActionError{"The box is already checking or updating. Wait for it to finish."}
	}
	dir := filepath.Join(b.Data, "settings")
	tmp, err := os.CreateTemp(dir, ".update-request-*")
	if err != nil {
		return err
	}
	_, err = tmp.WriteString(action + "\n")
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), b.requestFile())
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}

func (b *Box) requestFile() string { return filepath.Join(b.Data, "settings", "update-request") }

func (b *Box) busy() string {
	if a, err := os.ReadFile(filepath.Join(b.RunDir, "action")); err == nil {
		return strings.TrimSpace(string(a))
	}
	if a, err := os.ReadFile(b.requestFile()); err == nil {
		return strings.TrimSpace(string(a))
	}
	if _, err := os.Stat(b.RunDir); err == nil {
		return "update" // starting; it hasn't written its action yet
	}
	return ""
}

func (b *Box) updatesOn() bool {
	f, err := os.Open(b.UpdateEnv)
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "configuration="); ok {
			return strings.TrimSpace(v) != ""
		}
	}
	return false
}

// Version is the running system's, from its own nixos-version (cached until
// /run/current-system changes).
func (b *Box) Version() VersionInfo {
	target, _ := filepath.EvalSymlinks(b.System)
	b.mu.Lock()
	defer b.mu.Unlock()
	if target != "" && target == b.verFor {
		return b.version
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, b.NixosVersion, "--json").Output()
	var v struct {
		NixosVersion          string `json:"nixosVersion"`
		ConfigurationRevision string `json:"configurationRevision"`
	}
	if err != nil || json.Unmarshal(out, &v) != nil {
		return VersionInfo{}
	}
	b.verFor, b.version = target, VersionInfo{v.NixosVersion, v.ConfigurationRevision}
	return b.version
}

// restartNeeded: an update brought a new kernel, used after a restart.
func (b *Box) restartNeeded() bool {
	cur, err1 := filepath.EvalSymlinks(filepath.Join(b.System, "kernel"))
	boot, err2 := filepath.EvalSymlinks(filepath.Join(b.Booted, "kernel"))
	return err1 == nil && err2 == nil && cur != boot
}

type actionResult struct {
	Started  string `json:"started"`
	Finished string `json:"finished"`
	Exit     int    `json:"exit"`
}

func (b *Box) result(action string) (actionResult, []string, bool) {
	var r actionResult
	dir := filepath.Join(b.Data, "update")
	data, err := os.ReadFile(filepath.Join(dir, action+".json"))
	if err != nil || json.Unmarshal(data, &r) != nil {
		return r, nil, false
	}
	var lines []string
	if log, err := os.ReadFile(filepath.Join(dir, action+".log")); err == nil {
		for _, l := range strings.Split(strings.TrimRight(string(log), "\n"), "\n") {
			lines = append(lines, strings.TrimRight(l, "\r"))
		}
	}
	return r, lines, true
}

func firstField(s string) string {
	if f := strings.Fields(s); len(f) > 0 {
		return f[0]
	}
	return ""
}

func contains(lines []string, s string) bool {
	for _, l := range lines {
		if strings.TrimSpace(l) == s {
			return true
		}
	}
	return false
}

// failure is the error clankctl or the rebuild ended with: its last line.
func failure(log []string, fallback string) string {
	for i := len(log) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(log[i]); l != "" {
			return fallback + " " + strings.TrimPrefix(l, "clankctl: ")
		}
	}
	return fallback
}

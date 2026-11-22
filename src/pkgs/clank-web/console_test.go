package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseQR(t *testing.T) {
	m := parseQR("####  \n  ##  \n######\n")
	if len(m) != 3 || !m[0][0] || !m[0][1] || m[0][2] || m[1][0] || !m[2][2] {
		t.Fatalf("parse: %v", m)
	}
	if parseQR("##\n####\n") != nil {
		t.Fatal("a code that isn't square should be refused")
	}
}

func fakeQR(n int) [][]bool {
	m := make([][]bool, n)
	for i := range m {
		m[i] = make([]bool, n)
		for j := range m[i] {
			m[i][j] = (i+j)%2 == 0
		}
	}
	return m
}

func checkFits(t *testing.T, f *frame, cols, rows int) []string {
	t.Helper()
	lines := strings.Split(strings.TrimSuffix(f.Text(), "\n"), "\n")
	if len(lines) != rows {
		t.Fatalf("%d rows, want %d", len(lines), rows)
	}
	for _, l := range lines {
		if n := len([]rune(l)); n > cols {
			t.Fatalf("line of %d > %d: %q", n, cols, l)
		}
	}
	// The ANSI form never writes the bottom-right cell (no scrolling).
	if strings.Count(f.ANSI(), "\x1b[") == 0 {
		t.Fatal("no escapes")
	}
	return lines
}

func TestRenderConsole(t *testing.T) {
	v := ConsoleView{
		Step:     ConsoleReady,
		AppURL:   "https://clankstation.tail1234.ts.net/",
		LANAddr:  "192.168.1.20",
		Working:  1,
		Waiting:  2,
		NeedsYou: 1,
		Tasks: []ConsoleTask{
			{StateNeedsInput, "Make the contact form send an email to us, and a really long title that goes past the edge"},
			{StateRunning, "Fix the tests"},
		},
		Problems: []string{"The update didn't work. could not reach github"},
		Version:  "26.05.1 (abc1234)",
		Usage: []Usage{
			{"Memory", 52 << 30 / 10, 16 << 30},
			{"Projects", 80 << 30, 200 << 30},
			{"System", 37 << 29, 20 << 30},
			{"GPU memory", 2 << 30, 8 << 30},
		},
	}
	if v.QRURL() != v.AppURL {
		t.Fatalf("QR: %q", v.QRURL())
	}
	f := renderConsole(v, fakeQR(33), 80, 25)
	text := f.Text()
	lines := checkFits(t, f, 80, 25)
	for _, want := range []string{
		"Clankstation", "Open the app", "https://clankstation.tail1234.ts.net",
		"1 working   2 waiting   1 needs you", "Needs you Make the contact form", "Working   Fix the tests",
		"! The update didn't work.", "Version 26.05.1 (abc1234)", "This box", "5.2 GB of 16 GB", "80 GB of 200 GB", "18 GB of 20 GB", "2.0 GB of 8.0 GB",
		"For an admin login, press Alt+F2.",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
	// The QR code sits beside the text, 33 modules on 17 rows.
	if n := strings.Count(text, "▀"); n != 33*17 {
		t.Errorf("%d QR cells", n)
	}
	// Bars: 9 cells wide here; System is 93% used.
	for _, l := range lines {
		if strings.Contains(l, "System") && !strings.Contains(l, "████████░  18 GB of 20 GB") {
			t.Errorf("system bar: %q", l)
		}
	}
	if !strings.HasPrefix(lines[2], "  ▀") || !strings.Contains(lines[2], "Open the app") {
		t.Errorf("row 2: %q", lines[2])
	}

	// Set up, on a narrow console: the QR code goes below if it fits, and
	// points at the first-run page by address.
	v = ConsoleView{Step: ConsoleSetup, LANAddr: "192.168.1.20"}
	if v.QRURL() != "http://192.168.1.20/" {
		t.Fatalf("QR: %q", v.QRURL())
	}
	f = renderConsole(v, fakeQR(29), 60, 40)
	text = f.Text()
	checkFits(t, f, 60, 40)
	for _, want := range []string{"Set up this box", "http://clankstation.local", "or http://192.168.1.20", "Nothing running."} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in\n%s", want, text)
		}
	}
	if n := strings.Count(text, "▀"); n != 29*15 {
		t.Errorf("%d QR cells below", n)
	}
	// No room: no QR code, still the text.
	f = renderConsole(v, fakeQR(29), 60, 20)
	if strings.Contains(f.Text(), "▀") || !strings.Contains(f.Text(), "http://clankstation.local") {
		t.Errorf("small console:\n%s", f.Text())
	}

	// No network: no QR code at all.
	v = ConsoleView{Step: ConsoleOffline}
	if v.QRURL() != "" || !strings.Contains(renderConsole(v, nil, 80, 25).Text(), "Not connected to a network") {
		t.Error("offline")
	}
}

func TestGatherConsole(t *testing.T) {
	ts, sock := newFakeTailscaled(t)
	box, _ := testBox(t)
	store := &Store{Data: box.Data}
	fakeTask(t, box.Data, "t-20261121-120000-aaaa", "done") // its summary asks a question
	q := fakeTask(t, box.Data, "t-20261121-130000-bbbb", "")
	write(t, filepath.Join(q, "queued"), "2026-11-21T13:00:00Z\n")
	p := fakeTask(t, box.Data, "t-20261121-140000-cccc", "")
	write(t, filepath.Join(p, "prepare.pid"), "1\n") // pid 1 is alive
	write(t, filepath.Join(box.Data, "update", "update.json"), `{"started":"a","finished":"b","exit":1}`)
	write(t, filepath.Join(box.Data, "update", "update.log"), "clankctl: could not reach github\n")

	// Memory and GPU memory from fake /proc and /sys files.
	fake := t.TempDir()
	procMeminfo = filepath.Join(fake, "meminfo")
	drmDir = filepath.Join(fake, "drm")
	t.Cleanup(func() { procMeminfo, drmDir = "/proc/meminfo", "/sys/class/drm" })
	write(t, procMeminfo, "MemTotal:       16384000 kB\nMemFree:         1000000 kB\nMemAvailable:   12288000 kB\n")
	dev := filepath.Join(fake, "devices", "gpu0")
	must(t, os.MkdirAll(dev, 0o755))
	write(t, filepath.Join(dev, "mem_info_vram_total"), "8589934592\n")
	write(t, filepath.Join(dev, "mem_info_vram_used"), "1073741824\n")
	for _, c := range []string{"card0", "card0-DP-1"} {
		must(t, os.MkdirAll(filepath.Join(drmDir, c), 0o755))
		must(t, os.Symlink(dev, filepath.Join(drmDir, c, "device")))
	}

	get := func() ConsoleView {
		return gatherConsole(context.Background(), store, box, NewTailscale(sock))
	}
	v := get()
	if v.Working != 1 || v.Waiting != 1 || v.NeedsYou != 1 || len(v.Tasks) != 2 || v.Tasks[0].State != StateNeedsInput {
		t.Fatalf("tasks: %+v", v)
	}
	if v.Version != "26.05.1 (rev-1)" || len(v.Problems) == 0 || !strings.Contains(v.Problems[0], "could not reach github") {
		t.Fatalf("box: %+v", v)
	}
	if len(v.Usage) != 4 || v.Usage[0] != (Usage{"Memory", 4096000 << 10, 16384000 << 10}) ||
		v.Usage[1].Name != "Projects" || v.Usage[2].Name != "System" || v.Usage[1].Total == 0 ||
		v.Usage[3] != (Usage{"GPU memory", 1 << 30, 8 << 30}) {
		t.Fatalf("usage: %+v", v.Usage)
	}
	wantStep := ConsoleSetup
	if v.LANAddr == "" {
		wantStep = ConsoleOffline // a build sandbox has no network
	}
	if v.Step != wantStep {
		t.Fatalf("not on Tailscale: %q", v.Step)
	}

	ts.mu.Lock()
	ts.state = "Running"
	ts.mu.Unlock()
	if v := get(); v.Step != ConsoleReady || v.AppURL != "https://box.example.ts.net/" {
		t.Fatalf("on Tailscale: %+v", v)
	}

	// tailscaled not answering yet.
	v = gatherConsole(context.Background(), store, box, NewTailscale(filepath.Join(t.TempDir(), "none")))
	if v.Step != ConsoleStarting && v.Step != ConsoleOffline {
		t.Fatalf("no tailscaled: %q", v.Step)
	}
}

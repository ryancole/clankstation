package main

// The box's own screen (S9, design section 8): `clank-web -console` draws a
// read-only status page on the text console (tty1), in place of the login
// prompt. It says how to reach the app (with a QR code to scan), what the
// tasks are doing and what needs attention. Nothing here can change the box;
// the admin login is on Alt+F2 as usual.
//
// It reads the same things the app does: the task files, the box's version,
// updates and free space, and tailscaled's status. The QR code comes from
// qrencode (nixpkgs).

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// Console states: how far the box is from serving the app.
const (
	ConsoleStarting = "starting" // tailscaled isn't answering yet
	ConsoleOffline  = "offline"  // no network
	ConsoleSetup    = "setup"    // not on Tailscale: open the first-run page
	ConsoleFinish   = "finish"   // on Tailscale, HTTPS not on yet: the first-run page again
	ConsoleReady    = "ready"    // the app is at AppURL
)

type ConsoleView struct {
	Step     string
	AppURL   string // https://<name>/ when ready
	LANAddr  string // e.g. 192.168.1.20
	Problems []string
	Working  int
	Waiting  int
	NeedsYou int
	// Tasks to name: the ones that need you, then the ones working.
	Tasks   []ConsoleTask
	Version string
	// What the box is using: memory, then each disk, then each GPU's own
	// memory (only where the kernel reports it).
	Usage []Usage
}

type Usage struct {
	Name        string // Memory, Projects, System, GPU memory
	Used, Total uint64
}

// Where memory and GPU memory are read from (tests point them elsewhere).
var (
	procMeminfo = "/proc/meminfo"
	drmDir      = "/sys/class/drm"
)

// memoryUsage is RAM in use: MemTotal minus MemAvailable.
func memoryUsage() (Usage, bool) {
	kv := map[string]uint64{}
	b, err := os.ReadFile(procMeminfo)
	if err != nil {
		return Usage{}, false
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 {
			if n, err := strconv.ParseUint(f[1], 10, 64); err == nil {
				kv[strings.TrimSuffix(f[0], ":")] = n << 10 // kB
			}
		}
	}
	total, avail := kv["MemTotal"], kv["MemAvailable"]
	if total == 0 || avail > total {
		return Usage{}, false
	}
	return Usage{"Memory", total - avail, total}, true
}

// gpuUsage is each GPU's own memory (VRAM), from the amdgpu driver's
// mem_info_vram_* files. Integrated graphics share the RAM, and NVIDIA's
// driver (not on the box) reports none here: they show nothing.
func gpuUsage() []Usage {
	cards, _ := filepath.Glob(filepath.Join(drmDir, "card*", "device", "mem_info_vram_total"))
	sort.Strings(cards)
	var out []Usage
	seen := map[string]bool{}
	for _, tf := range cards {
		dev := filepath.Dir(tf)
		if real, err := filepath.EvalSymlinks(dev); err == nil {
			if seen[real] {
				continue // card0 and card0-DP-1 are the same device
			}
			seen[real] = true
		}
		total := readUint(tf)
		used := readUint(filepath.Join(dev, "mem_info_vram_used"))
		if total > 0 && used <= total {
			out = append(out, Usage{"GPU memory", used, total})
		}
	}
	if len(out) > 1 {
		for i := range out {
			out[i].Name = fmt.Sprintf("GPU %d memory", i+1)
		}
	}
	return out
}

func readUint(p string) uint64 {
	b, err := os.ReadFile(p)
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	return n
}

type ConsoleTask struct {
	State string // needs_input, running (any working state)
	Title string
}

// QRURL is what the QR code holds: the app, or the first-run page by
// address (a phone may not resolve clankstation.local).
func (v *ConsoleView) QRURL() string {
	switch {
	case v.Step == ConsoleReady:
		return v.AppURL
	case (v.Step == ConsoleSetup || v.Step == ConsoleFinish) && v.LANAddr != "":
		return "http://" + v.LANAddr + "/"
	}
	return ""
}

// gatherConsole reads the box's state for one frame.
func gatherConsole(ctx context.Context, store *Store, box *Box, ts *Tailscale) ConsoleView {
	v := ConsoleView{LANAddr: lanAddr()}

	tctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	st, err := ts.Status(tctx)
	cancel()
	switch {
	case err != nil:
		v.Step = ConsoleStarting
	case st.BackendState == "Running" && len(st.CertDomains) > 0:
		v.Step, v.AppURL = ConsoleReady, "https://"+st.CertDomains[0]+"/"
	case st.BackendState == "Running":
		v.Step = ConsoleFinish
	default:
		v.Step = ConsoleSetup
	}
	if v.LANAddr == "" && v.Step != ConsoleReady {
		v.Step = ConsoleOffline
	}

	for _, t := range store.List() {
		if t.Archived {
			continue
		}
		switch t.State {
		case StateRunning, StatePreparing, StateInteractive:
			v.Working++
		case StateQueued:
			v.Waiting++
		case StateNeedsInput:
			v.NeedsYou++
		}
	}
	// List is newest first; name the ones that need you first.
	for _, want := range []string{StateNeedsInput, StateRunning} {
		for _, t := range store.List() {
			s := t.State
			if s == StatePreparing || s == StateInteractive {
				s = StateRunning
			}
			if !t.Archived && s == want {
				v.Tasks = append(v.Tasks, ConsoleTask{want, t.Title})
			}
		}
	}

	bs := box.Status()
	v.Version = bs.Version.NixOS
	if r := bs.Version.Revision; r != "" {
		if len(r) > 7 {
			r = r[:7]
		}
		v.Version += " (" + r + ")"
	}
	if m, ok := memoryUsage(); ok {
		v.Usage = append(v.Usage, m)
	}
	for _, d := range bs.Disks {
		name := d.Name
		if name == "Tasks and projects" {
			name = "Projects"
		}
		v.Usage = append(v.Usage, Usage{name, d.Size - d.Free, d.Size})
	}
	v.Usage = append(v.Usage, gpuUsage()...)
	if u := bs.Update; u != nil && (u.Interrupted || (u.Finished != "" && !u.OK)) {
		v.Problems = append(v.Problems, u.Message)
	}
	if bs.RestartNeeded {
		v.Problems = append(v.Problems, "An update is waiting for a restart of the box.")
	}
	for _, d := range bs.Disks {
		if d.Size > 0 && (d.Free < 5<<30 || d.Free*20 < d.Size) {
			v.Problems = append(v.Problems, fmt.Sprintf("Disk almost full: %s, %s free.", strings.ToLower(d.Name), humanBytes(d.Free)))
		}
	}
	return v
}

// lanAddr is the box's first IPv4 address on the home network (not
// Tailscale, Docker or libvirt).
func lanAddr() string {
	ifs, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, i := range ifs {
		if i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
			continue
		}
		skip := false
		for _, p := range []string{"tailscale", "docker", "veth", "br-", "virbr", "vnet"} {
			skip = skip || strings.HasPrefix(i.Name, p)
		}
		if skip {
			continue
		}
		addrs, _ := i.Addrs()
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok {
				if ip4 := n.IP.To4(); ip4 != nil && ip4.IsGlobalUnicast() {
					return ip4.String()
				}
			}
		}
	}
	return ""
}

func humanBytes(n uint64) string {
	const gb = 1 << 30
	switch {
	case n >= 10*gb:
		return fmt.Sprintf("%d GB", n/gb)
	case n >= gb/10:
		return fmt.Sprintf("%.1f GB", float64(n)/gb)
	default:
		return fmt.Sprintf("%d MB", n>>20)
	}
}

// QR codes, from qrencode's ASCII output ("##" a dark module, "  " a light
// one, a row per line), margin included.
type QR struct {
	Path  string // qrencode executable
	mu    sync.Mutex
	cache map[string][][]bool
}

func (q *QR) Matrix(text string) [][]bool {
	if text == "" || q == nil || q.Path == "" {
		return nil
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if m, ok := q.cache[text]; ok {
		return m
	}
	out, err := exec.Command(q.Path, "-t", "ASCII", "-m", "2", "-l", "M", "-o", "-", text).Output()
	var m [][]bool
	if err == nil {
		m = parseQR(string(out))
	}
	if q.cache == nil {
		q.cache = map[string][][]bool{}
	}
	q.cache[text] = m
	return m
}

func parseQR(s string) [][]bool {
	var m [][]bool
	for _, line := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		row := make([]bool, 0, len(line)/2)
		for i := 0; i+1 < len(line); i += 2 {
			row = append(row, line[i] == '#')
		}
		m = append(m, row)
	}
	if len(m) == 0 || len(m[0]) != len(m) {
		return nil
	}
	return m
}

// The frame is a grid of cells, drawn whole each time it changes.
type cell struct {
	r      rune
	fg, bg int // ANSI colours 0-7; fg+8 is bright
	bold   bool
}

type style struct {
	fg, bg int
	bold   bool
}

var (
	stNormal  = style{fg: 7, bg: 0}
	stTitle   = style{fg: 15, bg: 0, bold: true}
	stURL     = style{fg: 14, bg: 0, bold: true}
	stMuted   = style{fg: 8, bg: 0}
	stWarn    = style{fg: 11, bg: 0, bold: true}
	stHeader  = style{fg: 15, bg: 4, bold: true}
	stLabelYo = style{fg: 11, bg: 0}
	stLabelOK = style{fg: 10, bg: 0}
)

type frame struct {
	cols, rows int
	c          [][]cell
}

func newFrame(cols, rows int) *frame {
	f := &frame{cols: cols, rows: rows, c: make([][]cell, rows)}
	for i := range f.c {
		f.c[i] = make([]cell, cols)
		for j := range f.c[i] {
			f.c[i][j] = cell{r: ' ', fg: 7}
		}
	}
	return f
}

// put writes text from (row, col), cut at the right edge or at max runes.
func (f *frame) put(row, col int, s string, st style) {
	if row < 0 || row >= f.rows {
		return
	}
	for _, r := range s {
		if col >= f.cols {
			return
		}
		if col >= 0 {
			f.c[row][col] = cell{r, st.fg, st.bg, st.bold}
		}
		col++
	}
}

func (f *frame) fill(row int, st style) {
	for j := 0; j < f.cols && row >= 0 && row < f.rows; j++ {
		f.c[row][j] = cell{' ', st.fg, st.bg, false}
	}
}

// Text is the frame without colours, a line per row (for tests).
func (f *frame) Text() string {
	var b strings.Builder
	for _, row := range f.c {
		line := make([]rune, len(row))
		for j, c := range row {
			line[j] = c.r
		}
		b.WriteString(strings.TrimRight(string(line), " "))
		b.WriteByte('\n')
	}
	return b.String()
}

// ANSI draws the frame from the top-left corner.
func (f *frame) ANSI() string { return strings.Join(f.ANSIRows(), "") }

// ANSIRows draws each row on its own (cursor to its start, then its cells),
// so only the rows that changed need redrawing. The bottom-right cell is
// left alone, so the console never scrolls.
func (f *frame) ANSIRows() []string {
	out := make([]string, f.rows)
	for i, row := range f.c {
		var b strings.Builder
		last := cell{r: -1}
		fmt.Fprintf(&b, "\x1b[%d;1H", i+1)
		for j, c := range row {
			if i == f.rows-1 && j == f.cols-1 {
				break
			}
			if c.fg != last.fg || c.bg != last.bg || c.bold != last.bold || last.r == -1 {
				b.WriteString("\x1b[0")
				if c.bold || c.fg >= 8 {
					b.WriteString(";1")
				}
				fmt.Fprintf(&b, ";%d;%dm", 30+c.fg%8, 40+c.bg%8)
				last = c
			}
			b.WriteRune(c.r)
		}
		out[i] = b.String()
	}
	return out
}

// renderConsole lays out a view on a cols x rows console.
func renderConsole(v ConsoleView, qr [][]bool, cols, rows int) *frame {
	f := newFrame(cols, rows)
	f.fill(0, stHeader)
	f.put(0, 2, "Clankstation", stHeader)

	// The QR code takes two module rows per text row (▀ with the top module
	// as the foreground and the bottom one as the background).
	qrW, qrH := 0, 0
	if qr != nil {
		qrW, qrH = len(qr), (len(qr)+1)/2
	}
	top, left := 2, 2
	textW := cols - 4
	qrBeside := qr != nil && cols >= qrW+4+40 && rows >= qrH+6
	if qrBeside {
		left = qrW + 6
		textW = cols - left - 2
	}

	var lines []struct {
		s  string
		st style
	}
	add := func(s string, st style) {
		lines = append(lines, struct {
			s  string
			st style
		}{s, st})
	}
	setup := func(title, lead string) {
		add(title, stTitle)
		add("", stNormal)
		add(lead, stNormal)
		add("http://clankstation.local", stURL)
		if v.LANAddr != "" {
			add("or http://"+v.LANAddr, stNormal)
		}
		add("", stNormal)
		add("Then follow the steps there.", stNormal)
	}
	switch v.Step {
	case ConsoleReady:
		add("Open the app", stTitle)
		add("", stNormal)
		add(strings.TrimSuffix(v.AppURL, "/"), stURL)
		add("on a phone or PC signed in to your Tailscale.", stNormal)
	case ConsoleSetup:
		setup("Set up this box", "On a phone or PC on the same network as this box, open")
	case ConsoleFinish:
		setup("Finish setting up", "The box is on your Tailscale. To finish, on a phone or PC on the same network, open")
	case ConsoleOffline:
		add("Not connected to a network", stTitle)
		add("", stNormal)
		add("Plug a network cable into the box. This screen updates by itself.", stNormal)
	default:
		add("Starting up...", stTitle)
	}

	add("", stNormal)
	add("Tasks", stTitle)
	if v.Working+v.Waiting+v.NeedsYou == 0 {
		add("Nothing running.", stNormal)
	} else {
		add(fmt.Sprintf("%d working   %d waiting   %d need%s you", v.Working, v.Waiting, v.NeedsYou, plural1(v.NeedsYou)), stNormal)
	}

	// The footer takes the last two rows; above it, what the box is using
	// (if there's room). Problems and task names go after the fixed lines,
	// as room allows.
	usageTop := rows - 3 - len(v.Usage) // its title row
	if len(v.Usage) == 0 || usageTop-2 < top+8 {
		usageTop = rows - 2
	} else {
		f.put(usageTop, left, "This box", stTitle)
		for i, u := range v.Usage {
			drawUsage(f, usageTop+1+i, left, textW, u)
		}
	}
	maxRow := usageTop - 2
	row := top
	for _, l := range lines {
		for _, w := range wrap(l.s, textW) {
			if row > maxRow {
				break
			}
			f.put(row, left, w, l.st)
			row++
		}
	}
	for _, t := range v.Tasks {
		if row > maxRow {
			break
		}
		label, st := "Working   ", stLabelOK
		if t.State == StateNeedsInput {
			label, st = "Needs you ", stLabelYo
		}
		f.put(row, left, label, st)
		f.put(row, left+len(label), clip(t.Title, textW-len(label)), stNormal)
		row++
	}
	if len(v.Problems) > 0 && row <= maxRow {
		row++
		for _, p := range v.Problems {
			for i, w := range wrap(p, textW-2) {
				if row > maxRow {
					break
				}
				if i == 0 {
					f.put(row, left, "!", stWarn)
				}
				f.put(row, left+2, w, stWarn)
				row++
			}
		}
	}

	if qr != nil {
		qTop, qLeft := top, 2
		if !qrBeside {
			qTop = row + 1
			qLeft = (cols - qrW) / 2
		}
		if qrBeside || qTop+qrH <= usageTop-1 {
			for r := 0; r < qrH; r++ {
				for c := 0; c < qrW; c++ {
					color := func(dark bool) int {
						if dark {
							return 0
						}
						return 7
					}
					up := qr[2*r][c]
					down := false
					if 2*r+1 < len(qr) {
						down = qr[2*r+1][c]
					}
					if qTop+r < rows && qLeft+c < cols {
						f.c[qTop+r][qLeft+c] = cell{'▀', color(up), color(down), false}
					}
				}
			}
		}
	}

	if v.Version != "" {
		f.put(rows-2, 2, clip("Version "+v.Version, cols-4), stMuted)
	}
	f.put(rows-1, 2, "For an admin login, press Alt+F2.", stMuted)
	return f
}

// drawUsage draws one "Memory  ██████░░░░░░  5.2 of 16 GB" row: green, then
// yellow from 70% used, red from 90%.
func drawUsage(f *frame, row, col, width int, u Usage) {
	const labelW = 13
	amount := fmt.Sprintf("%s of %s", humanBytes(u.Used), humanBytes(u.Total))
	barW := width - labelW - 2 - len(amount)
	if barW > 30 {
		barW = 30
	}
	f.put(row, col, clip(u.Name, labelW-1), stNormal)
	if barW < 6 || u.Total == 0 { // too narrow for a bar: the numbers alone
		f.put(row, col+labelW, clip(amount, width-labelW), stNormal)
		return
	}
	frac := float64(u.Used) / float64(u.Total)
	fill := int(frac*float64(barW) + 0.5)
	if fill > barW {
		fill = barW
	}
	st := stLabelOK
	switch {
	case frac >= 0.9:
		st = style{fg: 9, bg: 0}
	case frac >= 0.7:
		st = stLabelYo
	}
	f.put(row, col+labelW, strings.Repeat("█", fill), st)
	f.put(row, col+labelW+fill, strings.Repeat("░", barW-fill), stMuted)
	f.put(row, col+labelW+barW+2, amount, stNormal)
}

func plural1(n int) string {
	if n == 1 {
		return "s"
	}
	return ""
}

func clip(s string, n int) string {
	r := []rune(s)
	if n <= 0 {
		return ""
	}
	if len(r) <= n {
		return s
	}
	if n <= 3 {
		return string(r[:n])
	}
	return string(r[:n-3]) + "..."
}

// wrap breaks s into lines of at most n runes, at spaces where it can.
func wrap(s string, n int) []string {
	if len([]rune(s)) <= n || s == "" {
		return []string{s}
	}
	var out []string
	var line []rune
	for _, word := range strings.Fields(s) {
		w := []rune(word)
		for len(w) > n && n > 0 {
			if len(line) > 0 {
				out = append(out, string(line))
				line = nil
			}
			out = append(out, string(w[:n]))
			w = w[n:]
		}
		switch {
		case len(line) == 0:
			line = w
		case len(line)+1+len(w) <= n:
			line = append(append(line, ' '), w...)
		default:
			out = append(out, string(line))
			line = w
		}
	}
	if len(line) > 0 {
		out = append(out, string(line))
	}
	return out
}

// runConsole draws the status page on the terminal it was started on until
// it is stopped.
func runConsole(store *Store, box *Box, ts *Tailscale, qr *QR, every time.Duration) error {
	out := os.Stdout
	quiet := setQuiet(int(os.Stdin.Fd()))
	defer quiet()
	// Keys typed at the console go nowhere (Alt+F2 switches consoles in the
	// kernel, before this).
	go func() {
		buf := make([]byte, 64)
		for {
			if _, err := os.Stdin.Read(buf); err != nil {
				return
			}
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	defer fmt.Fprint(out, "\x1b[0m\x1b[2J\x1b[H\x1b[?25h")

	fmt.Fprint(out, "\x1b[0m\x1b[2J\x1b[?25l")
	var last []string
	tick := time.NewTicker(every)
	defer tick.Stop()
	for {
		cols, rows := termSize(int(out.Fd()))
		v := gatherConsole(context.Background(), store, box, ts)
		now := renderConsole(v, qr.Matrix(v.QRURL()), cols, rows).ANSIRows()
		var b strings.Builder
		for i, r := range now {
			if len(last) != len(now) || last[i] != r {
				b.WriteString(r)
			}
		}
		if b.Len() > 0 {
			if _, err := fmt.Fprint(out, b.String()); err != nil {
				return err
			}
		}
		last = now
		select {
		case <-stop:
			return nil
		case <-tick.C:
		}
	}
}

func termSize(fd int) (cols, rows int) {
	var ws struct{ Row, Col, X, Y uint16 }
	_, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&ws)))
	if e != 0 || ws.Col < 20 || ws.Row < 10 {
		return 80, 25
	}
	return int(ws.Col), int(ws.Row)
}

// setQuiet turns off echo and line editing on the terminal (so keys don't
// print over the page) and returns a function that restores them.
func setQuiet(fd int) func() {
	var t syscall.Termios
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCGETS, uintptr(unsafe.Pointer(&t))); e != 0 {
		return func() {}
	}
	old := t
	t.Lflag &^= syscall.ECHO | syscall.ICANON
	syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&t)))
	return func() {
		syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.TCSETS, uintptr(unsafe.Pointer(&old)))
	}
}

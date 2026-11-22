package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

func TestNotificationFor(t *testing.T) {
	task := func(state string, turns int) TaskSummary {
		return TaskSummary{ID: "t-20261122-120000-aaaa", Title: "Fix the form", State: state, Turns: turns, Activity: "It works now."}
	}
	cases := []struct {
		prev      string
		now       TaskSummary
		wantTitle string // "" = no notification
	}{
		{"running/1", task(StateDone, 1), "Done: Fix the form"},
		{"running/1", task(StateNeedsInput, 1), "Claude has a question"},
		{"running/1", task(StateFailed, 1), "Didn't finish: Fix the form"},
		{"running/1", task(StateLost, 1), "Interrupted: Fix the form"},
		{"preparing/1", task(StateDone, 1), "Done: Fix the form"},
		{"running/1", task(StateStopped, 1), ""},             // you stopped it
		{"queued/1", task(StateStopped, 1), ""},              // taken out of line
		{"done/1", task(StateDone, 1), ""},                   // nothing new
		{"done/1", task(StateDone, 2), "Done: Fix the form"}, // a whole reply between looks
		{"", task(StateDone, 1), "Done: Fix the form"},       // started and finished between looks
		{"", task(StateQueued, 1), ""},
		{"done/1", task(StateRunning, 2), ""},
	}
	for _, c := range cases {
		n := notificationFor(c.prev, c.now)
		got := ""
		if n != nil {
			got = n.Title
			if n.URL != "/#/task/t-20261122-120000-aaaa" || n.Tag != "t-20261122-120000-aaaa" {
				t.Errorf("%s -> %s: url %q tag %q", c.prev, seenKey(c.now), n.URL, n.Tag)
			}
		}
		if got != c.wantTitle {
			t.Errorf("%s -> %s: %q, want %q", c.prev, seenKey(c.now), got, c.wantTitle)
		}
	}
	if n := notificationFor("running/1", task(StateNeedsInput, 1)); n.Body != "It works now." {
		t.Errorf("question body %q", n.Body)
	}
}

// fakeDevice is a browser's side of a push subscription: it can decrypt
// what the push service hands over (RFC 8291, aes128gcm).
type fakeDevice struct {
	key  *ecdh.PrivateKey
	auth []byte
}

func newFakeDevice(t *testing.T) *fakeDevice {
	k, err := ecdh.P256().GenerateKey(rand.Reader)
	must(t, err)
	auth := make([]byte, 16)
	rand.Read(auth)
	return &fakeDevice{k, auth}
}

func (d *fakeDevice) subscription(endpoint string) webpush.Subscription {
	enc := base64.RawURLEncoding.EncodeToString
	return webpush.Subscription{Endpoint: endpoint, Keys: webpush.Keys{
		P256dh: enc(d.key.PublicKey().Bytes()), Auth: enc(d.auth)}}
}

func (d *fakeDevice) decrypt(t *testing.T, body []byte) []byte {
	t.Helper()
	salt, rs := body[:16], binary.BigEndian.Uint32(body[16:20])
	idlen := int(body[20])
	asPub, ct := body[21:21+idlen], body[21+idlen:]
	if int(rs) < len(ct) {
		t.Fatalf("record size %d < %d", rs, len(ct))
	}
	peer, err := ecdh.P256().NewPublicKey(asPub)
	must(t, err)
	shared, err := d.key.ECDH(peer)
	must(t, err)
	info := append(append([]byte("WebPush: info\x00"), d.key.PublicKey().Bytes()...), asPub...)
	prkKey, _ := hkdf.Extract(sha256.New, shared, d.auth)
	ikm, _ := hkdf.Expand(sha256.New, prkKey, string(info), 32)
	prk, _ := hkdf.Extract(sha256.New, ikm, salt)
	cek, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: aes128gcm\x00", 16)
	nonce, _ := hkdf.Expand(sha256.New, prk, "Content-Encoding: nonce\x00", 12)
	block, _ := aes.NewCipher(cek)
	gcm, _ := cipher.NewGCM(block)
	pt, err := gcm.Open(nil, nonce, ct, nil)
	must(t, err)
	pt = bytes.TrimRight(pt, "\x00")
	if len(pt) == 0 || pt[len(pt)-1] != 2 {
		t.Fatalf("no last-record delimiter")
	}
	return pt[:len(pt)-1]
}

type fakePushService struct {
	mu     sync.Mutex
	got    [][]byte
	hdrs   []http.Header
	status int
}

func (f *fakePushService) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	b, _ := io.ReadAll(r.Body)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.got = append(f.got, b)
	f.hdrs = append(f.hdrs, r.Header.Clone())
	if f.status != 0 {
		w.WriteHeader(f.status)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

func (f *fakePushService) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.got)
}

func TestPushSendAndNotifier(t *testing.T) {
	root := t.TempDir()
	svc := &fakePushService{}
	srv := httptest.NewServer(svc)
	defer srv.Close()

	p, err := OpenPush(filepath.Join(root, "settings", "push"), func() string { return "https://box.example.ts.net" })
	must(t, err)
	info, _ := os.Stat(filepath.Join(root, "settings", "push", "vapid.json"))
	if info.Mode().Perm() != 0o600 {
		t.Errorf("vapid.json mode %v", info.Mode())
	}
	// The key pair survives a restart.
	p2, err := OpenPush(filepath.Join(root, "settings", "push"), p.subject)
	must(t, err)
	if p2.PublicKey() != p.PublicKey() || p.PublicKey() == "" {
		t.Error("VAPID key changed on reopen")
	}

	dev := newFakeDevice(t)
	must(t, p.Subscribe(dev.subscription(srv.URL+"/push/abc"), &Identity{Login: "alice@example.com", Node: "phone"}))
	if err := p.Subscribe(webpush.Subscription{Endpoint: "ftp://x"}, nil); err == nil {
		t.Error("bad subscription accepted")
	}

	// Send: encrypted for the device, VAPID-signed as the box.
	must(t, p.Send(context.Background(), Notification{Title: "Done: Fix the form", Body: "It works.", URL: "/#/task/x", Tag: "t-20261122-120000-aaaa"}, ""))
	if svc.count() != 1 {
		t.Fatalf("push service got %d", svc.count())
	}
	h := svc.hdrs[0]
	if h.Get("Content-Encoding") != "aes128gcm" || !strings.HasPrefix(h.Get("Authorization"), "vapid t=") ||
		!strings.Contains(h.Get("Authorization"), "k="+p.PublicKey()) || h.Get("TTL") != "86400" ||
		h.Get("Topic") != "t-20261122-120000-aaaa" || h.Get("Urgency") != "high" {
		t.Errorf("headers %v", h)
	}
	var n Notification
	must(t, json.Unmarshal(dev.decrypt(t, svc.got[0]), &n))
	if n.Title != "Done: Fix the form" || n.URL != "/#/task/x" {
		t.Errorf("decrypted %+v", n)
	}

	// A test to one device only; an unknown device is refused.
	if err := p.Send(context.Background(), Notification{Title: "x"}, "https://nope.example/1"); err == nil {
		t.Error("test to an unknown device accepted")
	}

	// The notifier: a task finishing sends one; a restart in between is
	// remembered (seen.json), and a task lost to it is reported.
	running := map[string]bool{}
	store := &Store{Data: root, Push: p, Running: func() (map[string]bool, error) { return running, nil }}
	dir := fakeTask(t, root, "t-20261122-120000-aaaa", "")
	running["t-20261122-120000-aaaa"] = true
	nt := NewNotifier(store, p)
	nt.seen = map[string]string{}
	nt.tick(context.Background(), true) // first look: no notifications
	before := svc.count()
	write(t, filepath.Join(dir, "status.json"), `{"state":"done","session_id":"s","finished":"2026-11-22T12:00:00Z"}`)
	write(t, filepath.Join(dir, "result", "summary.md"), "All done here.")
	running = map[string]bool{}
	nt.tick(context.Background(), false)
	if svc.count() != before+1 {
		t.Fatalf("finishing sent %d", svc.count()-before)
	}
	must(t, json.Unmarshal(dev.decrypt(t, svc.got[len(svc.got)-1]), &n))
	if n.Title != "Done: Make the contact form send an email" || n.Body != "All done here." {
		t.Errorf("notification %+v", n)
	}
	nt.tick(context.Background(), false)
	if svc.count() != before+1 {
		t.Error("same state notified twice")
	}

	// It was running when the box went down, and came back lost.
	os.Remove(filepath.Join(dir, "status.json"))
	running["t-20261122-120000-aaaa"] = true
	nt.tick(context.Background(), false)
	running = map[string]bool{}
	restarted := NewNotifier(store, p)
	ctx, cancel := context.WithCancel(context.Background())
	go restarted.Run(ctx, time.Hour)
	deadline := time.Now().Add(5 * time.Second)
	for svc.count() < before+2 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	if svc.count() != before+2 {
		t.Fatalf("lost task after restart sent %d", svc.count()-before-1)
	}
	must(t, json.Unmarshal(dev.decrypt(t, svc.got[len(svc.got)-1]), &n))
	if !strings.HasPrefix(n.Title, "Interrupted:") {
		t.Errorf("after restart: %+v", n)
	}

	// A device whose subscription is gone is forgotten.
	svc.mu.Lock()
	svc.status = http.StatusGone
	svc.mu.Unlock()
	_ = p.Send(context.Background(), Notification{Title: "x"}, "")
	if len(p.subs) != 0 {
		t.Error("gone subscription kept")
	}
}

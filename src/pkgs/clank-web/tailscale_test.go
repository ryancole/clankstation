package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"
)

// fakeTailscaled serves the LocalAPI calls clank-web makes, on a Unix socket.
type fakeTailscaled struct {
	mu        sync.Mutex
	state     string
	authURL   string
	certOK    bool
	logins    int
	known     map[string]string // ip -> login name
	certPEM   []byte
	certDelay time.Duration // Let's Encrypt is slow the first time
	lastHost  string
	origin    bool
}

func newFakeTailscaled(t *testing.T) (*fakeTailscaled, string) {
	t.Helper()
	f := &fakeTailscaled{state: "NeedsLogin", known: map[string]string{}}
	f.certPEM = selfSignedPair(t, "box.example.ts.net")
	sock := filepath.Join(t.TempDir(), "ts.sock")
	l, err := net.Listen("unix", sock)
	must(t, err)
	srv := &http.Server{Handler: f}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })
	return f, sock
}

func (f *fakeTailscaled) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lastHost = r.Host
	if r.Header.Get("Origin") != "" || r.Referer() != "" {
		f.origin = true
	}
	p := strings.TrimPrefix(r.URL.Path, "/localapi/v0/")
	switch {
	case p == "status":
		st := map[string]any{"BackendState": f.state, "AuthURL": f.authURL}
		if f.state == "Running" {
			st["CertDomains"] = []string{"box.example.ts.net"}
			st["Self"] = map[string]string{"DNSName": "box.example.ts.net.", "HostName": "box"}
			st["CurrentTailnet"] = map[string]string{"Name": "example.com"}
		}
		json.NewEncoder(w).Encode(st)
	case p == "prefs" && r.Method == http.MethodPatch:
		io.Copy(io.Discard, r.Body)
		w.Write([]byte("{}"))
	case p == "login-interactive" && r.Method == http.MethodPost:
		f.logins++
		f.authURL = "https://login.tailscale.com/a/abc123"
		w.WriteHeader(http.StatusNoContent)
	case p == "whois":
		ip, _, _ := net.SplitHostPort(r.URL.Query().Get("addr"))
		login, ok := f.known[ip]
		if !ok {
			http.Error(w, "no match for IP:port", http.StatusNotFound)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{
			"Node":        map[string]string{"Name": "phone.example.ts.net.", "ComputedName": "phone"},
			"UserProfile": map[string]string{"LoginName": login, "DisplayName": "Alice"},
		})
	case strings.HasPrefix(p, "cert/"):
		f.mu.Unlock()
		time.Sleep(f.certDelay)
		f.mu.Lock()
		if !f.certOK {
			http.Error(w, "acme: HTTPS not enabled", http.StatusInternalServerError)
			return
		}
		if r.URL.Query().Get("type") != "pair" || p != "cert/box.example.ts.net" {
			http.Error(w, "bad cert request", 400)
			return
		}
		w.Write(f.certPEM)
	default:
		http.NotFound(w, r)
	}
}

func selfSignedPair(t *testing.T, name string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(t, err)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(90 * 24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	must(t, err)
	kb, err := x509.MarshalECPrivateKey(key)
	must(t, err)
	return append(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kb}),
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})...)
}

func TestTailscaleLogin(t *testing.T) {
	f, sock := newFakeTailscaled(t)
	ts := NewTailscale(sock)
	f.known["127.0.0.1"] = "alice@example.com"

	root := t.TempDir()
	app := newServer(&Store{Data: root}, &Clankctl{Path: "false"}, fstest.MapFS{"index.html": {Data: []byte("app")}})
	srv := httptest.NewServer(ts.RequireTailnet(app))
	defer srv.Close()

	// A device Tailscale knows gets in, as itself.
	resp, err := http.Get(srv.URL + "/api/me")
	must(t, err)
	var me Identity
	must(t, json.NewDecoder(resp.Body).Decode(&me))
	if resp.StatusCode != 200 || me.Login != "alice@example.com" || me.Node != "phone" {
		t.Fatalf("me = %d %+v", resp.StatusCode, me)
	}
	if f.lastHost != localAPIHost || f.origin {
		t.Errorf("LocalAPI request: host %q, origin sent %v", f.lastHost, f.origin)
	}

	// One it doesn't know (after the cache) is turned away.
	ts.whoisMu.Lock()
	ts.whoisCache = map[string]whoisEntry{}
	ts.whoisMu.Unlock()
	delete(f.known, "127.0.0.1")
	resp, err = http.Get(srv.URL + "/")
	must(t, err)
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusForbidden || !strings.Contains(string(body), "Tailscale network") {
		t.Errorf("unknown device: %d %s", resp.StatusCode, body)
	}

	if !isTailnetAddr("100.101.102.103:443") || !isTailnetAddr("[fd7a:115c:a1e0::1]:443") || isTailnetAddr("192.168.1.5:443") {
		t.Error("isTailnetAddr")
	}
}

func TestSetupAndCertificate(t *testing.T) {
	f, sock := newFakeTailscaled(t)
	ts := NewTailscale(sock)
	srv := httptest.NewServer(setupHandler(ts))
	defer srv.Close()
	noFollow := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	page := func() string {
		t.Helper()
		resp, err := http.Get(srv.URL + "/")
		must(t, err)
		b, _ := io.ReadAll(resp.Body)
		return string(b)
	}

	if p := page(); !strings.Contains(p, "Connect to Tailscale") {
		t.Fatalf("first page: %s", p)
	}
	// Browsers send Origin: null on form posts under "no-referrer", which the
	// cross-site check refuses: the page must not use it.
	r0, err := http.Get(srv.URL + "/")
	must(t, err)
	if rp := r0.Header.Get("Referrer-Policy"); rp != "same-origin" {
		t.Errorf("Referrer-Policy %q", rp)
	}
	// Another site's page can't start the sign-in.
	req, _ := http.NewRequest("POST", srv.URL+"/setup/connect", nil)
	req.Header.Set("Origin", "http://evil.example")
	resp, err := noFollow.Do(req)
	must(t, err)
	if resp.StatusCode != http.StatusForbidden || f.logins != 0 {
		t.Fatalf("cross-site connect: %d, logins %d", resp.StatusCode, f.logins)
	}
	resp, err = noFollow.Post(srv.URL+"/setup/connect", "", nil)
	must(t, err)
	if resp.StatusCode != http.StatusSeeOther || f.logins != 1 {
		t.Fatalf("connect: %d, logins %d", resp.StatusCode, f.logins)
	}
	if p := page(); !strings.Contains(p, "https://login.tailscale.com/a/abc123") {
		t.Fatalf("sign-in page: %s", p)
	}

	// waitPage polls like the page's own refresh does.
	waitPage := func(want string) string {
		t.Helper()
		var p string
		for i := 0; i < 100; i++ {
			if p = page(); strings.Contains(p, want) {
				return p
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatalf("page never showed %q: %s", want, p)
		return ""
	}

	// Connected, but HTTPS isn't on in the tailnet yet: the fetch runs in the
	// background (the page says so), then the page asks to enable HTTPS.
	f.mu.Lock()
	f.state, f.authURL, f.certDelay = "Running", "", 200*time.Millisecond
	f.mu.Unlock()
	if p := page(); !strings.Contains(p, "about a minute") {
		t.Fatalf("certificate-pending page: %s", p)
	}
	waitPage("Enable HTTPS")
	// Once connected, the LAN page can't start another sign-in.
	resp, err = noFollow.Post(srv.URL+"/setup/connect", "", nil)
	must(t, err)
	if f.logins != 1 {
		t.Errorf("connect while running started a login")
	}

	f.mu.Lock()
	f.certOK = true
	f.mu.Unlock()
	ts.certMu.Lock()
	ts.certTried = time.Time{}
	ts.certMu.Unlock()
	waitPage("https://box.example.ts.net/")

	// The HTTPS listener serves that certificate.
	c, err := ts.TLSConfig().GetCertificate(&tls.ClientHelloInfo{ServerName: "box.example.ts.net"})
	must(t, err)
	if c.Leaf.Subject.CommonName != "box.example.ts.net" {
		t.Errorf("cert for %s", c.Leaf.Subject.CommonName)
	}
	// Kept: tailscaled isn't asked again while it's valid.
	f.mu.Lock()
	f.certOK = false
	f.mu.Unlock()
	if _, _, err := ts.Certificate(t.Context()); err != nil {
		t.Errorf("cached cert: %v", err)
	}
}

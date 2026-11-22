package main

// Tailscale (S5, design section 3): the app is served over HTTPS on the box's
// *.ts.net name with Tailscale's certificate, and the login is the
// connecting device's Tailscale identity. Everything goes through the local
// tailscaled's LocalAPI on its Unix socket:
//
//   GET  /localapi/v0/status?peers=false   state, sign-in link, our name
//   GET  /localapi/v0/whois?addr=ip:port   who a connecting device belongs to
//   GET  /localapi/v0/cert/<name>?type=pair  key + certificate (PEM); needs
//                                          TS_PERMIT_CERT_UID = our uid
//   POST /localapi/v0/login-interactive    start Tailscale's own sign-in
//   PATCH /localapi/v0/prefs               WantRunning (needs --operator)
//
// The box never sees Tailscale credentials: the person signs in on
// Tailscale's site, through the link tailscaled hands out.

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"time"
)

const localAPIHost = "local-tailscaled.sock"

type Tailscale struct {
	client *http.Client

	whoisMu    sync.Mutex
	whoisCache map[string]whoisEntry

	certMu       sync.Mutex
	cert         *tls.Certificate
	certName     string
	certErr      error
	certTried    time.Time
	certFetching bool
}

// certTimeout bounds one certificate fetch. The first one for a name has
// Tailscale set a DNS record and ask Let's Encrypt, which took 34 s on the
// dev VM; later ones come from tailscaled's own cache.
const certTimeout = 5 * time.Minute

// errCertPending: a certificate is being fetched in the background.
var errCertPending = errors.New("getting the certificate")

type whoisEntry struct {
	id  *Identity
	at  time.Time
	err error
}

func NewTailscale(socket string) *Tailscale {
	return &Tailscale{
		client: &http.Client{
			// Each call is bounded by its context (callCtx, or certTimeout).
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", socket)
				},
			},
		},
		whoisCache: map[string]whoisEntry{},
	}
}

// call makes a LocalAPI request. tailscaled refuses requests with an Origin
// or Referer, or another Host, so none are sent.
func (t *Tailscale) call(ctx context.Context, method, path string, body any, out any) error {
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
	}
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://"+localAPIHost+"/localapi/v0/"+path, rd)
	if err != nil {
		return err
	}
	resp, err := t.client.Do(req)
	if err != nil {
		return fmt.Errorf("tailscale isn't reachable: %w", err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode/100 != 2 {
		return &tsError{resp.StatusCode, strings.TrimSpace(string(data))}
	}
	if out == nil {
		return nil
	}
	if raw, ok := out.(*[]byte); ok {
		*raw = data
		return nil
	}
	return json.Unmarshal(data, out)
}

type tsError struct {
	Code int
	Msg  string
}

func (e *tsError) Error() string { return fmt.Sprintf("tailscale: %d %s", e.Code, e.Msg) }

type TSStatus struct {
	BackendState string // NoState, NeedsLogin, NeedsMachineAuth, Stopped, Starting, Running
	AuthURL      string
	Self         *struct {
		DNSName  string
		HostName string
	}
	CertDomains    []string
	CurrentTailnet *struct{ Name string }
}

func (t *Tailscale) Status(ctx context.Context) (*TSStatus, error) {
	var st TSStatus
	if err := t.call(ctx, http.MethodGet, "status?peers=false", nil, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

// Name is the box's HTTPS name, e.g. clankstation.tail1234.ts.net.
func (st *TSStatus) Name() string {
	if len(st.CertDomains) > 0 {
		return st.CertDomains[0]
	}
	if st.Self != nil {
		return strings.TrimSuffix(st.Self.DNSName, ".")
	}
	return ""
}

// StartLogin asks tailscaled to start Tailscale's own sign-in (its link
// then shows up in Status().AuthURL) and to connect once signed in.
func (t *Tailscale) StartLogin(ctx context.Context) error {
	prefs := map[string]bool{"WantRunning": true, "WantRunningSet": true}
	if err := t.call(ctx, http.MethodPatch, "prefs", prefs, nil); err != nil {
		return err
	}
	return t.call(ctx, http.MethodPost, "login-interactive", nil, nil)
}

// Identity is who a device on the tailnet belongs to.
type Identity struct {
	Login string `json:"login"` // e.g. alice@example.com
	Name  string `json:"name"`  // e.g. Alice Smith
	Node  string `json:"node"`  // the device's name
}

// WhoIs asks Tailscale who the device at remoteAddr (ip:port) belongs to.
// Answers are kept for a minute per address.
func (t *Tailscale) WhoIs(ctx context.Context, remoteAddr string) (*Identity, error) {
	ap, err := netip.ParseAddrPort(remoteAddr)
	if err != nil {
		return nil, err
	}
	key := ap.Addr().String()
	t.whoisMu.Lock()
	if e, ok := t.whoisCache[key]; ok && time.Since(e.at) < time.Minute {
		t.whoisMu.Unlock()
		return e.id, e.err
	}
	t.whoisMu.Unlock()

	var res struct {
		Node *struct {
			Name         string
			ComputedName string
		}
		UserProfile *struct {
			LoginName   string
			DisplayName string
		}
	}
	err = t.call(ctx, http.MethodGet, "whois?addr="+url.QueryEscape(ap.String()), nil, &res)
	var id *Identity
	if err == nil {
		if res.UserProfile == nil || res.Node == nil {
			err = errors.New("tailscale: incomplete whois answer")
		} else {
			id = &Identity{Login: res.UserProfile.LoginName, Name: res.UserProfile.DisplayName, Node: res.Node.ComputedName}
			if id.Node == "" {
				id.Node = strings.TrimSuffix(res.Node.Name, ".")
			}
		}
	}
	var te *tsError
	if err != nil && !(errors.As(err, &te) && te.Code == http.StatusNotFound) {
		return nil, err // tailscaled trouble: don't remember it
	}
	t.whoisMu.Lock()
	t.whoisCache[key] = whoisEntry{id: id, at: time.Now(), err: err}
	t.whoisMu.Unlock()
	return id, err
}

// Certificate returns the box's certificate for its ts.net name, fetched
// from tailscaled (which gets and renews it from Let's Encrypt). It's kept
// until two weeks before it expires. Fetching happens in the background, so
// callers never wait for Let's Encrypt: until the first certificate arrives
// this returns errCertPending (or the last fetch's error, retried after
// 30 s); after that, the cached one while a renewal runs.
func (t *Tailscale) Certificate(ctx context.Context) (*tls.Certificate, string, error) {
	t.certMu.Lock()
	defer t.certMu.Unlock()
	if t.cert != nil && time.Until(t.cert.Leaf.NotAfter) > 14*24*time.Hour {
		return t.cert, t.certName, nil
	}
	if t.certFetching {
		return t.cert, t.certName, errCertPending
	}
	if t.certErr != nil && time.Since(t.certTried) < 30*time.Second {
		return t.cert, t.certName, t.certErr
	}
	st, err := t.Status(ctx)
	if err != nil {
		return t.cert, "", err
	}
	name := st.Name()
	if st.BackendState != "Running" || name == "" {
		return t.cert, name, errors.New("tailscale isn't connected yet")
	}
	t.certFetching, t.certName = true, name
	go t.fetchCert(name)
	return t.cert, name, errCertPending
}

func (t *Tailscale) fetchCert(name string) {
	ctx, cancel := context.WithTimeout(context.Background(), certTimeout)
	defer cancel()
	var c tls.Certificate
	var pem []byte
	err := t.call(ctx, http.MethodGet, "cert/"+url.PathEscape(name)+"?type=pair", nil, &pem)
	if err == nil {
		c, err = tls.X509KeyPair(pem, pem)
	}
	if err == nil {
		c.Leaf, err = x509.ParseCertificate(c.Certificate[0])
	}
	t.certMu.Lock()
	defer t.certMu.Unlock()
	t.certFetching, t.certTried, t.certErr = false, time.Now(), err
	if err == nil {
		t.cert = &c
	}
}

// TLSConfig serves the ts.net certificate.
func (t *Tailscale) TLSConfig() *tls.Config {
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()
			c, _, err := t.Certificate(ctx)
			if c != nil {
				return c, nil // still valid; a renewal failure is retried later
			}
			if err == nil {
				err = errors.New("no certificate yet")
			}
			return nil, err
		},
	}
}

type identityKey struct{}

func identityFrom(ctx context.Context) *Identity {
	id, _ := ctx.Value(identityKey{}).(*Identity)
	return id
}

// RequireTailnet lets through only devices Tailscale can name: the login.
func (t *Tailscale) RequireTailnet(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := t.WhoIs(r.Context(), r.RemoteAddr)
		if err != nil || id == nil {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusForbidden)
			_ = notOnTailnetPage.Execute(w, nil)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), identityKey{}, id)))
	})
}

// isTailnetAddr reports whether a remote address is a Tailscale one
// (100.64.0.0/10 or fd7a:115c:a1e0::/48).
func isTailnetAddr(remoteAddr string) bool {
	ap, err := netip.ParseAddrPort(remoteAddr)
	if err != nil {
		return false
	}
	a := ap.Addr().Unmap()
	return netip.MustParsePrefix("100.64.0.0/10").Contains(a) ||
		netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(a)
}

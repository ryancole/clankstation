// clank-web: the Clankstation service (design section 8). It serves the
// embedded web app and a JSON API over the task files that clankctl writes,
// live task events over Server-Sent Events, and actions through clankctl.
//
// Listeners (S5):
//
//	-https  the app over HTTPS on the box's *.ts.net name; only devices on the
//	        tailnet get in, and their Tailscale identity is the login
//	-setup  plain HTTP on the LAN: the first-run page that joins Tailscale
//	-listen the app over plain HTTP with no login: the dev VM only
package main

import (
	"context"
	"crypto/tls"
	"embed"
	"encoding/json"
	"flag"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"
)

//go:embed all:ui/dist
var uiFiles embed.FS

func init() {
	_ = mime.AddExtensionType(".webmanifest", "application/manifest+json")
}

func main() {
	httpsAddr := flag.String("https", "", "address for the app over HTTPS on Tailscale, e.g. :443")
	setupAddr := flag.String("setup", "", "address for the first-run page over plain HTTP, e.g. :80")
	devAddr := flag.String("listen", "", "address for the app over plain HTTP with NO login (dev only)")
	tsSock := flag.String("tailscale-socket", "/run/tailscale/tailscaled.sock", "tailscaled's LocalAPI socket")
	certFile := flag.String("tls-cert", "", "serve -https with this certificate instead of Tailscale's (tests)")
	keyFile := flag.String("tls-key", "", "key for -tls-cert")
	data := flag.String("data", "/var/lib/clankstation", "Clankstation data root")
	dockerSock := flag.String("docker", "/run/docker.sock", "Docker socket (to see which tasks run)")
	clankctl := flag.String("clankctl", "clankctl", "clankctl executable (for actions)")
	user := flag.String("user", "default", "household user for new tasks (CLANK_USER)")
	flag.Parse()

	running, invalidate := dockerRunning(*dockerSock)
	store := &Store{Data: *data, Running: running, Invalidate: invalidate}
	ui, err := fs.Sub(uiFiles, "ui/dist")
	if err != nil {
		log.Fatal(err)
	}
	app := newServer(store, &Clankctl{Path: *clankctl, User: *user}, ui)
	ts := NewTailscale(*tsSock)

	errs := make(chan error, 3)
	serve := func(name string, srv *http.Server, tls bool) {
		log.Printf("clank-web: %s on %s", name, srv.Addr)
		if tls {
			errs <- srv.ListenAndServeTLS("", "")
		} else {
			errs <- srv.ListenAndServe()
		}
	}
	if *httpsAddr != "" {
		tlsConf := ts.TLSConfig()
		if *certFile != "" {
			c, err := tls.LoadX509KeyPair(*certFile, *keyFile)
			if err != nil {
				log.Fatal(err)
			}
			tlsConf = &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{c}}
		}
		go serve("app (HTTPS, Tailscale login)", &http.Server{
			Addr: *httpsAddr, Handler: ts.RequireTailnet(app), TLSConfig: tlsConf,
			ReadHeaderTimeout: 10 * time.Second,
		}, true)
	}
	if *setupAddr != "" {
		go serve("first-run page (HTTP)", &http.Server{
			Addr: *setupAddr, Handler: setupHandler(ts), ReadHeaderTimeout: 10 * time.Second,
		}, false)
	}
	if *devAddr != "" {
		dev := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			id := &Identity{Login: "dev", Name: "Dev VM (no login)", Node: "dev"}
			app.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), identityKey{}, id)))
		})
		go serve("app (plain HTTP, NO login, dev only)", &http.Server{
			Addr: *devAddr, Handler: dev, ReadHeaderTimeout: 10 * time.Second,
		}, false)
	}
	if *httpsAddr == "" && *setupAddr == "" && *devAddr == "" {
		log.Fatal("clank-web: nothing to serve (set -https, -setup or -listen)")
	}
	log.Fatal(<-errs)
}

// dockerRunning asks the Docker API which task containers are running
// (clankctl labels them clankstation.task=<id>). Cached for a second; the
// second function drops the cache (after an action changed something).
func dockerRunning(sock string) (func() (map[string]bool, error), func()) {
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
	}
	var mu sync.Mutex
	var cached map[string]bool
	var at time.Time
	q := url.Values{"filters": {`{"label":["clankstation.task"],"status":["running"]}`}}
	get := func() (map[string]bool, error) {
		mu.Lock()
		defer mu.Unlock()
		if cached != nil && time.Since(at) < time.Second {
			return cached, nil
		}
		resp, err := client.Get("http://docker/containers/json?" + q.Encode())
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		var cs []struct {
			Labels map[string]string `json:"Labels"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&cs); err != nil {
			return nil, err
		}
		m := map[string]bool{}
		for _, c := range cs {
			if id := c.Labels["clankstation.task"]; id != "" {
				m[id] = true
			}
		}
		cached, at = m, time.Now()
		return m, nil
	}
	invalidate := func() {
		mu.Lock()
		cached = nil
		mu.Unlock()
	}
	return get, invalidate
}

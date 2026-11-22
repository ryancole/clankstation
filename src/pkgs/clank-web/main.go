// clank-web: the Clankstation service (design section 8). S1: read-only.
// It serves the embedded web app and a JSON API over the task files that
// clankctl writes, plus live task events over Server-Sent Events.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"flag"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"time"
)

//go:embed all:ui/dist
var uiFiles embed.FS

func main() {
	listen := flag.String("listen", "127.0.0.1:8080", "address to listen on")
	data := flag.String("data", "/var/lib/clankstation", "Clankstation data root")
	dockerSock := flag.String("docker", "/run/docker.sock", "Docker socket (to see which tasks run)")
	flag.Parse()

	store := &Store{Data: *data, Running: dockerRunning(*dockerSock)}
	ui, err := fs.Sub(uiFiles, "ui/dist")
	if err != nil {
		log.Fatal(err)
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           newServer(store, ui),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("clank-web listening on %s (data %s)", *listen, *data)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
	os.Exit(1)
}

// dockerRunning asks the Docker API which task containers are running
// (clankctl labels them clankstation.task=<id>). Cached for a second.
func dockerRunning(sock string) func() (map[string]bool, error) {
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
	}
	var cached map[string]bool
	var at time.Time
	q := url.Values{"filters": {`{"label":["clankstation.task"],"status":["running"]}`}}
	return func() (map[string]bool, error) {
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
}

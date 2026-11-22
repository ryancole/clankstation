package main

// The first-run page (S5, design section 3, "Joining Tailscale"), on plain
// HTTP at http://clankstation.local. It is the only thing served without
// Tailscale: it connects the box to Tailscale through Tailscale's own
// sign-in link, then points to the box's https://…ts.net address. Once the
// box is connected, it does nothing else.

import (
	"context"
	"errors"
	"html/template"
	"net/http"
	"time"
)

type setupView struct {
	Step    string // offline, connect, signin, waiting, certs, certwait, ready
	AuthURL string
	Name    string // the box's ts.net name
	Tailnet string
	Error   string
	Refresh bool
}

func setupHandler(ts *Tailscale) http.Handler {
	mux := http.NewServeMux()
	view := func(ctx context.Context) setupView {
		st, err := ts.Status(ctx)
		if err != nil {
			return setupView{Step: "offline", Error: err.Error(), Refresh: true}
		}
		v := setupView{Name: st.Name()}
		if st.CurrentTailnet != nil {
			v.Tailnet = st.CurrentTailnet.Name
		}
		switch st.BackendState {
		case "Running":
			switch c, _, err := ts.Certificate(ctx); {
			case c != nil:
				v.Step = "ready"
			case errors.Is(err, errCertPending):
				v.Step, v.Refresh = "certwait", true
			default:
				v.Step, v.Error, v.Refresh = "certs", err.Error(), true
			}
		case "NeedsLogin", "NoState", "Stopped":
			if st.AuthURL != "" {
				v.Step, v.AuthURL, v.Refresh = "signin", st.AuthURL, true
			} else {
				v.Step = "connect"
			}
		default: // Starting, NeedsMachineAuth
			v.Step, v.Refresh = "waiting", true
			if st.AuthURL != "" {
				v.Step, v.AuthURL = "signin", st.AuthURL
			}
		}
		return v
	}

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 45*time.Second)
		defer cancel()
		v := view(ctx)
		// A device already on the tailnet goes straight to the app.
		if v.Step == "ready" && isTailnetAddr(r.RemoteAddr) {
			http.Redirect(w, r, "https://"+v.Name+"/", http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_ = setupPage.Execute(w, v)
	})
	mux.HandleFunc("POST /setup/connect", func(w http.ResponseWriter, r *http.Request) {
		if !sameOrigin(w, r) {
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		// Only while the box isn't connected: once it is, nobody on the LAN
		// can move it to another tailnet from here.
		if st, err := ts.Status(ctx); err == nil && (st.BackendState == "Running" || st.BackendState == "Starting") {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		if err := ts.StartLogin(ctx); err != nil {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_ = setupPage.Execute(w, setupView{Step: "connect", Error: err.Error()})
			return
		}
		// tailscaled fetches the sign-in link from Tailscale; give it a moment.
		for i := 0; i < 20; i++ {
			if st, err := ts.Status(ctx); err == nil && st.AuthURL != "" {
				break
			}
			time.Sleep(500 * time.Millisecond)
		}
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/", http.StatusFound)
	})
	return securityHeaders(mux)
}

const pageStyle = `
:root { color-scheme: light dark; --bg:#f6f7f9; --card:#fff; --text:#15181d; --muted:#59606b; --border:#e2e5ea; --accent:#2459d6; --accent-text:#fff; --warn-bg:#fdf1e6; --warn:#8a4006; }
@media (prefers-color-scheme: dark) { :root { --bg:#111317; --card:#1a1d23; --text:#e8eaee; --muted:#9aa1ac; --border:#2a2e36; --accent:#6b93f0; --accent-text:#0d1426; --warn-bg:#3d2712; --warn:#f6c08f; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font-family: Inter, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 560px; margin: 0 auto; padding: 32px 16px; }
h1 { font-size: 26px; margin: 0 0 8px; }
p, li { font-size: 16px; line-height: 1.5; color: var(--text); }
.muted { color: var(--muted); font-size: 14px; }
.card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 20px 18px; margin: 20px 0; }
.btn { display:inline-flex; align-items:center; justify-content:center; min-height:52px; padding:0 22px; border-radius:14px; border:0; background:var(--accent); color:var(--accent-text); font:inherit; font-size:16px; font-weight:600; text-decoration:none; cursor:pointer; width:100%; }
.warn { background: var(--warn-bg); color: var(--warn); border-radius: 12px; padding: 10px 14px; font-size: 14px; overflow-wrap:anywhere; }
code { font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 0.95em; overflow-wrap:anywhere; }
ol { padding-left: 22px; }
`

var setupPage = template.Must(template.New("setup").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{{if .Refresh}}<meta http-equiv="refresh" content="4">{{end}}
<title>Set up Clankstation</title>
<style>` + pageStyle + `</style></head>
<body><main>
<h1>Set up Clankstation</h1>
{{if eq .Step "ready"}}
  <p>Your Clankstation is ready. Open it at its own address, from home or anywhere:</p>
  <div class="card">
    <p><code>https://{{.Name}}</code></p>
    <a class="btn" href="https://{{.Name}}/">Open Clankstation</a>
  </div>
  <p class="muted">Each phone or computer that uses Clankstation needs the Tailscale app, signed in to
  {{if .Tailnet}}<strong>{{.Tailnet}}</strong>{{else}}the same Tailscale account{{end}}.
  Get it from tailscale.com/download or your app store.</p>
{{else if eq .Step "connect"}}
  <p>Clankstation uses <strong>Tailscale</strong> so your phone and computer can reach it safely,
  at home and away. You need a free Tailscale account.</p>
  <div class="card">
    <form method="post" action="/setup/connect"><button class="btn" type="submit">Connect to Tailscale</button></form>
  </div>
  {{if .Error}}<p class="warn">{{.Error}}</p>{{end}}
  <p class="muted">You'll sign in on Tailscale's own website. Clankstation never sees your Tailscale password.</p>
{{else if eq .Step "signin"}}
  <p>Sign in to Tailscale to add this box to your Tailscale network. The link opens Tailscale's own website.</p>
  <div class="card"><a class="btn" href="{{.AuthURL}}" target="_blank" rel="noopener">Sign in to Tailscale</a></div>
  <p class="muted">This page updates by itself once you're signed in.</p>
{{else if eq .Step "certs"}}
  <p>The box is connected to Tailscale{{if .Tailnet}} (<strong>{{.Tailnet}}</strong>){{end}}. One more step:
  let Tailscale give it a secure (HTTPS) address.</p>
  <div class="card">
    <ol>
      <li>Open the <a href="https://login.tailscale.com/admin/dns" target="_blank" rel="noopener">DNS page of the Tailscale admin console</a>.</li>
      <li>Turn on <strong>MagicDNS</strong> if it's off.</li>
      <li>Under <strong>HTTPS Certificates</strong>, choose <strong>Enable HTTPS</strong>.</li>
    </ol>
  </div>
  <p class="muted">This page checks again by itself. The first certificate can take a minute.</p>
  {{if .Error}}<p class="warn">Details: {{.Error}}</p>{{end}}
{{else if eq .Step "certwait"}}
  <p>The box is connected to Tailscale{{if .Tailnet}} (<strong>{{.Tailnet}}</strong>){{end}}.
  Getting its secure (HTTPS) certificate: the first one takes about a minute.</p>
  <p class="muted">This page updates by itself.</p>
{{else if eq .Step "waiting"}}
  <p>Connecting to Tailscale…</p>
{{else}}
  <p>The box's Tailscale service isn't answering yet. This page tries again by itself.</p>
  {{if .Error}}<p class="warn">Details: {{.Error}}</p>{{end}}
{{end}}
</main></body></html>`))

var notOnTailnetPage = template.Must(template.New("denied").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Clankstation</title>
<style>` + pageStyle + `</style></head>
<body><main>
<h1>This device can't use Clankstation</h1>
<p>Clankstation only opens on devices signed in to its Tailscale network.
Open the Tailscale app on this device, make sure it's connected and signed in to the right account, then reload.</p>
</main></body></html>`))

package main

// Push notifications (S6, docs/gui.md section 5). The box has its own VAPID
// key pair; each device that turns notifications on sends its Web Push
// subscription. Both are kept in settings/push/ on the data disk:
//
//   vapid.json          the box's key pair (0600)
//   subscriptions.json  one entry per device: endpoint, keys, who, when
//   seen.json           each task's last state, so a restart doesn't
//                       repeat or miss a notification
//
// A notifier polls the task list and sends one notification when a turn
// ends: done, needs an answer, failed, or interrupted by a restart. Nothing
// for steps, for a task you stopped, or one taken out of line.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	webpush "github.com/SherClockHolmes/webpush-go"
)

type Push struct {
	dir     string
	subject func() string // the box's https URL, for the VAPID "sub" claim
	client  webpush.HTTPClient

	mu   sync.Mutex
	pub  string
	priv string
	subs []PushSub
}

type PushSub struct {
	Sub    webpush.Subscription `json:"subscription"`
	Login  string               `json:"login"`
	Device string               `json:"device"`
	Added  string               `json:"added"`
}

type Notification struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	URL   string `json:"url"`
	Tag   string `json:"tag"` // one notification per task: a newer one replaces it
}

func OpenPush(dir string, subject func() string) (*Push, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	p := &Push{dir: dir, subject: subject, client: &http.Client{Timeout: 30 * time.Second}}
	var keys struct{ Public, Private string }
	if b, err := os.ReadFile(filepath.Join(dir, "vapid.json")); err == nil && json.Unmarshal(b, &keys) == nil && keys.Public != "" {
		p.pub, p.priv = keys.Public, keys.Private
	} else {
		priv, pub, err := webpush.GenerateVAPIDKeys()
		if err != nil {
			return nil, err
		}
		keys.Public, keys.Private = pub, priv
		if err := writeJSONFile(filepath.Join(dir, "vapid.json"), keys, 0o600); err != nil {
			return nil, err
		}
		p.pub, p.priv = pub, priv
	}
	if b, err := os.ReadFile(filepath.Join(dir, "subscriptions.json")); err == nil {
		_ = json.Unmarshal(b, &p.subs)
	}
	return p, nil
}

func writeJSONFile(path string, v any, mode os.FileMode) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (p *Push) PublicKey() string { return p.pub }

func (p *Push) saveLocked() error {
	return writeJSONFile(filepath.Join(p.dir, "subscriptions.json"), p.subs, 0o600)
}

func validSubscription(s webpush.Subscription) error {
	u, err := url.Parse(s.Endpoint)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return &ActionError{"That isn't a push subscription."}
	}
	if s.Keys.Auth == "" || s.Keys.P256dh == "" {
		return &ActionError{"That push subscription has no keys."}
	}
	return nil
}

// Subscribe adds a device, or updates it if its endpoint is known.
func (p *Push) Subscribe(s webpush.Subscription, id *Identity) error {
	if err := validSubscription(s); err != nil {
		return err
	}
	e := PushSub{Sub: s, Added: time.Now().UTC().Format(time.RFC3339)}
	if id != nil {
		e.Login, e.Device = id.Login, id.Node
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := range p.subs {
		if p.subs[i].Sub.Endpoint == s.Endpoint {
			p.subs[i] = e
			return p.saveLocked()
		}
	}
	p.subs = append(p.subs, e)
	return p.saveLocked()
}

func (p *Push) Unsubscribe(endpoint string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := p.subs[:0]
	for _, s := range p.subs {
		if s.Sub.Endpoint != endpoint {
			out = append(out, s)
		}
	}
	p.subs = out
	return p.saveLocked()
}

// Send delivers n to every device, or only to the one with endpoint `only`.
// A device whose subscription is gone (404/410) is forgotten.
func (p *Push) Send(ctx context.Context, n Notification, only string) error {
	p.mu.Lock()
	subs := append([]PushSub(nil), p.subs...)
	p.mu.Unlock()
	msg, _ := json.Marshal(n)
	var errs []error
	found := false
	for _, s := range subs {
		if only != "" && s.Sub.Endpoint != only {
			continue
		}
		found = true
		sub := s.Sub
		resp, err := webpush.SendNotificationWithContext(ctx, msg, &sub, &webpush.Options{
			HTTPClient:      p.client,
			Subscriber:      p.subject(),
			VAPIDPublicKey:  p.pub,
			VAPIDPrivateKey: p.priv,
			TTL:             24 * 60 * 60,
			Urgency:         webpush.UrgencyHigh,
			Topic:           topicFor(n.Tag),
		})
		if err != nil {
			errs = append(errs, err)
			continue
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		resp.Body.Close()
		switch {
		case resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusGone:
			log.Printf("push: %s is no longer subscribed; forgetting it", s.Device)
			_ = p.Unsubscribe(s.Sub.Endpoint)
		case resp.StatusCode/100 != 2:
			errs = append(errs, fmt.Errorf("push service said %d: %s", resp.StatusCode, bytes.TrimSpace(body)))
		}
	}
	if only != "" && !found {
		return &ActionError{"This device isn't signed up for notifications yet."}
	}
	return errors.Join(errs...)
}

// topicFor makes a Topic header (at most 32 URL-safe characters) so a push
// service replaces an undelivered notification for the same task.
func topicFor(tag string) string {
	out := make([]byte, 0, 32)
	for i := 0; i < len(tag) && len(out) < 32; i++ {
		c := tag[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' {
			out = append(out, c)
		}
	}
	return string(out)
}

// ---- the notifier ------------------------------------------------------------

type Notifier struct {
	store    *Store
	push     *Push
	seenPath string
	seen     map[string]string // task id -> "state/turns"
}

func NewNotifier(store *Store, push *Push) *Notifier {
	return &Notifier{store: store, push: push, seenPath: filepath.Join(push.dir, "seen.json")}
}

func isActive(state string) bool {
	return state == StateQueued || state == StatePreparing || state == StateRunning || state == StateInteractive
}

func seenKey(t TaskSummary) string { return fmt.Sprintf("%s/%d", t.State, t.Turns) }

// notificationFor says what to send when a task moves from prev to t, or
// nil. prev is "" for a task the notifier hasn't seen before.
func notificationFor(prev string, t TaskSummary) *Notification {
	if isActive(t.State) || prev == seenKey(t) {
		return nil
	}
	prevState, prevTurnsText, _ := strings.Cut(prev, "/")
	prevTurns, _ := strconv.Atoi(prevTurnsText)
	// A turn ended: it was working, or a whole turn went by between looks.
	if prev != "" && !isActive(prevState) && t.Turns <= prevTurns {
		return nil
	}
	title := t.Title
	if title == "" {
		title = "your task"
	}
	n := &Notification{URL: "/#/task/" + t.ID, Tag: t.ID}
	switch t.State {
	case StateDone:
		n.Title, n.Body = "Done: "+title, t.Activity
	case StateNeedsInput:
		n.Title, n.Body = "Claude has a question", t.Activity
	case StateFailed:
		n.Title, n.Body = "Didn't finish: "+title, "Tap to see what happened"
	case StateLost:
		n.Title, n.Body = "Interrupted: "+title, "The box restarted. Tap to continue"
	default: // stopped: you did that yourself
		return nil
	}
	if n.Body == "" {
		n.Body = "Tap to see what it did"
	}
	return n
}

// Run checks the task list every few seconds until ctx ends.
func (nt *Notifier) Run(ctx context.Context, every time.Duration) {
	first := true
	if b, err := os.ReadFile(nt.seenPath); err == nil && json.Unmarshal(b, &nt.seen) == nil {
		first = false // compare with how things were before a restart
	}
	if nt.seen == nil {
		nt.seen = map[string]string{}
	}
	for {
		nt.tick(ctx, first)
		first = false
		select {
		case <-ctx.Done():
			return
		case <-time.After(every):
		}
	}
}

func (nt *Notifier) tick(ctx context.Context, baseline bool) {
	tasks := nt.store.List()
	changed := false
	now := map[string]bool{}
	for _, t := range tasks {
		now[t.ID] = true
		key := seenKey(t)
		prev, known := nt.seen[t.ID]
		if known && prev == key {
			continue
		}
		if !baseline {
			if n := notificationFor(prev, t); n != nil {
				sctx, cancel := context.WithTimeout(ctx, 60*time.Second)
				if err := nt.push.Send(sctx, *n, ""); err != nil {
					log.Printf("push: %s: %v", t.ID, err)
				}
				cancel()
			}
		}
		nt.seen[t.ID] = key
		changed = true
	}
	for id := range nt.seen {
		if !now[id] {
			delete(nt.seen, id)
			changed = true
		}
	}
	if changed {
		if err := writeJSONFile(nt.seenPath, nt.seen, 0o600); err != nil {
			log.Printf("push: %v", err)
		}
	}
}

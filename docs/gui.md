# Clankstation GUI

Status: draft, 2026-11-21. Screens and flows for the first client, the
installable web app (PWA) served by the box (design section 3, "First client").
No stack is chosen yet; nothing here depends on one.

Written for the people who will use it: someone in the household who wants a
coding job done and has never opened a terminal. Plain words on every screen.
Technical detail is always one tap away, never in the way.

## 1. Words we use

| On screen | Means | Never say |
|---|---|---|
| Task | One job you gave Claude, with all its back-and-forth | session, run, container |
| Project | A code repository the box knows about | repo, mirror, remote |
| Changes | What Claude changed in the project's files | diff, patch, worktree |
| Reply | Tell Claude what to do next, in the same task | resume, turn |
| Summary | Claude's own account of what it did | result event |

## 2. Task states as people see them

The box already knows these per task (`clankctl`'s `task_state` and
`status.json`). The GUI shows one label, one colour and one sentence.

| Box state | Label | Sentence on the task page | What you can do |
|---|---|---|---|
| `queued` | Waiting in line, and its place ("Next in line") | "It starts by itself when a task ahead of it finishes." | Take it out of line |
| `preparing` | Getting ready | "Setting up the project's tools. This can take a few minutes the first time." | Stop |
| `running` | Working | The current activity line (section 4) | Stop |
| `running`, after `clankctl attach` over SSH | You're in control | "Someone is working with Claude in a terminal." | (none) |
| `done`, summary ends with a question | Needs your answer | Claude's question, large | Reply |
| `done` | Finished | "Done. Here's what it did." | Reply |
| `failed` | Something went wrong | First line of the error in plain words, if known | Reply ("try again") |
| `stopped` | Stopped | "Stopped before it finished. Its work so far is kept." | Reply ("keep going") |
| `lost` | Interrupted | "The box restarted while this was working." | Reply ("keep going") |
| any, with `pruned` | Archived | "Its working files were cleaned up after 7 days. You can still read it." | Read only |

**Needs your answer** is the one state the box doesn't record today. In headless
mode Claude Code can't stop mid-turn to ask; it ends the turn, and its final
message is the question. First version: a finished turn whose summary's last
paragraph contains a question (a `?` ending a sentence, outside code and
URLs, as in "Do you want a fourth fact? If so, …") is shown as *Needs your
answer*. Every finished task
can be replied to anyway, so a wrong guess costs nothing. How this is detected
long-term belongs to the event protocol decision.

## 3. Screens

### 3.1 Home: "Your tasks"

The screen the app opens on. Task cards in three groups, most urgent first:

1. **Needs you**: *Needs your answer*, *Something went wrong*, *Interrupted*.
2. **Working**: *Waiting in line*, *Getting ready*, *Working*, *You're in control*.
3. **Done**: *Finished*, *Stopped*, *Archived*. Newest first, the last 7 days, then "Show older".

Each card shows:
- Title: the first line of the first prompt (`prompts.log`), cut to two lines.
- Project name and how long ago it started or finished.
- The state label.
- One more line: the live activity while working, the first sentence of the
  summary when finished, the question when it needs an answer.

A large **New task** button sits at the bottom (thumb reach on a phone; top
right on a PC). Empty state: "Nothing yet. Give Claude its first task."
A settings button (gear) sits in the top bar.

Data: `tasks/*/task.env`, `prompts.log`, the task state, `result/summary.md`,
and the tail of `events.jsonl` for the activity line.

### 3.2 New task

1. **Which project?** A list of projects (`projects/*/project.env`), the one
   used last on top. "Add a project" at the end (3.6).
2. **What should Claude do?** A big text box. Placeholder: "Describe what you
   want, like you'd tell a colleague. For example: Fix the typo on the About
   page and make the contact form send an email."
3. **Start.** Goes straight to the new task's page (3.3), which shows *Getting
   ready* or *Waiting in line*.

No other fields on day one. Branch, template and base commit stay as
`clankctl` defaults. If Claude isn't set up or signed in, this screen says so
and links to Settings instead of letting a task fail.

### 3.3 Task page

One page per task that changes with its state. From the top:

- **Header:** title, project, state label and sentence (section 2), elapsed or
  finished time.
- **While working:**
  - **Now:** one plain-language line for the latest step, such as "Editing
    `contact.py`" or "Running the tests" (section 4).
  - **Plan:** Claude's to-do list as a checklist, when it keeps one. Ticked
    items show progress without any guessing.
  - **What Claude is saying:** its latest message text.
  - Buttons: **Stop** (asks first: "Its work so far is kept, and you can tell
    Claude to keep going later").
- **When finished:**
  - **Summary:** `result/summary.md` rendered as formatted text.
  - **What changed:** "3 files changed" with each file name and a small
    added/removed bar (`result/diffstat.txt`). Tap a file to see its changes
    (3.4). "No files were changed" when the diff is empty.
  - **Reply box:** "Tell Claude what to do next" with a **Send** button
    (inside the question box when Claude asked one).
    Sending starts a new turn in the same task (`clankctl resume`).
  - Later: **Send to GitHub** (open a PR).
- **History** (below, collapsed after the latest turn): each earlier turn as
  "You asked" (from `prompts.log`) and "Claude did" (that turn's final
  message from `events.jsonl`). A take-over turn shows as "You worked with
  Claude in the terminal".
- **Details** (collapsed, for the curious): every step in order, with tool
  inputs and outputs; task id, branch, cost and duration from the `result`
  event; `stderr.log`, `prepare.log`, `lifecycle.log`.

### 3.4 Changes

One file at a time, so it fits a phone. A file picker on top, then the
changes: removed lines red, added lines green, unchanged lines folded. New
files say "New file", deleted files "Deleted". Wide lines wrap. Source:
`result/diff.patch` (or the live diff while working, as `clankctl diff` does).

### 3.5 Take over (removed for now)

Built in S3 (a browser terminal running Claude Code's own interactive screen,
with a hand-back button) and taken out of the app in S4: everything goes
through the queue, and nothing interrupts a run. To steer a task, **Stop**
it and reply. Over SSH, `clankctl attach` still works.

### 3.6 Projects

A list of projects with the last task's date. **Add a project:** a name and
the git URL ("the address you'd use to clone it"). It runs `clankctl project
add`; a failed clone shows git's message under "Details".

### 3.7 Settings

- **You (S5):** your name and Tailscale login, and which device you're on.
  "Your Tailscale account is your Clankstation login."
- **Claude:** installed version and whether it's signed in (`claude auth
  status`). **Set up Claude** (installs it, `clankctl harness enable claude`)
  and **Sign in**, which opens a browser terminal running Claude's own sign-in
  (`claude auth login`). The app only carries keystrokes to and from that
  terminal. It never reads, logs or stores what passes through it.
  On a phone the terminal stays above the keyboard and has a key row
  (Paste, Esc, Tab, Ctrl, arrows, Enter) with **Paste** (iPhones offer no paste menu inside a terminal): it reads the
  clipboard, or opens a box to paste the sign-in code into.
  (Built in S3. Settings also links to Projects.)
- **Notifications (S6, under "This device"):** Turn on / Turn off for this
  device, and **Test** once on. On iPhone in Safari (not installed), a note
  to add Clankstation to the home screen first, since iPhones only offer
  notifications to installed web apps. If a test doesn't show up, it may be
  hidden by a Focus mode (Sleep, Do Not Disturb), or by iOS while the app
  is open on screen: it's in Notification Center.
- **Install the app:** instructions for this browser (Add to Home Screen /
  Install).
- **The box (S7):** the version (Clankstation's commit and NixOS), **Check
  for updates** (asks GitHub only when tapped), then **Update now** when a
  newer version is out (asks first; "Updating…" while it builds, and "The
  app is restarting" if the page loses the box on the way). The result
  ("Updated.", or why it didn't work), with the last update's output under
  "Details". A note to restart the box when an update brought a new kernel
  (no restart button). Free space: "Tasks and projects" (the data disk) and
  "System". Projects is linked below.

### 3.8 On a PC (S8)

Most people give Claude its tasks from a PC, so a wide window gets more than
a stretched phone page. Phones (under 900px wide) keep the screens above as
they are.

- **From 900px: two panes.** The task list sits on the left all the time: the
  **New task** button on top, then the three groups from Home (3.1) as
  compact rows (title, project, state label, the activity or summary line),
  then **Projects** and **Settings** at the bottom. The open task is
  highlighted. Everything else (task page, New task, Projects, Settings,
  Changes) opens on the right. With nothing open, the right side says "Pick a
  task on the left, or start a new one" with a **New task** button. The list
  keeps refreshing (every few seconds, as Home does) whatever is open on the
  right, so a task finishing elsewhere shows up without a reload.
- **From 1400px: three panes on a task page.** The task's changes sit to the
  right of the conversation once a turn has left any: the file list, then
  the selected file's changes, with line numbers. They are the changes as of
  Claude's last finished turn (`result/diff.patch`), and refresh when the
  next turn ends. "See all changes" opens the full Changes page instead.
- **Changes on a wide screen.** The files are a list beside the changes, not
  a picker, and lines have numbers. Long lines don't wrap; the changes
  scroll sideways. A
  **Side by side** / **One column** switch shows old and new next to each
  other; the choice is remembered on that device.
- Pages keep the same addresses as on a phone (`#/task/<id>` and so on), so
  a link or notification opens the same place on either.

### 3.9 The box's own screen (S9)

A monitor plugged into the box shows a status page, not a login prompt. It
can't change anything; it only says where to go. It updates by itself every
few seconds.

- **Top:** what to do next, with a QR code to scan for it:
  - Not on Tailscale yet: "Set up this box. On a phone or PC on the same
    network as this box, open http://clankstation.local (or http://<the
    box's address>). Then follow the steps there." The QR code opens the
    first-run page by address, since some phones can't find `.local` names.
  - On Tailscale, HTTPS not turned on yet: "Finish setting up", the same way.
  - Ready: "Open the app", its `https://…ts.net` address and "on a phone or
    PC signed in to your Tailscale." The QR code opens the app.
  - No network: "Not connected to a network. Plug a network cable into the
    box." No QR code.
- **Tasks:** "2 working   1 waiting   1 needs you" (or "Nothing running."),
  then a row for each task that needs you ("Needs you" and its title), then
  each task working, as many as fit.
- **Problems,** marked "!": an update that didn't work or didn't finish, an
  update waiting for a restart, a disk almost full (under 5 GB or 5% free).
- **Bottom:** the version, free space, and "For an admin login, press
  Alt+F2."

## 4. Turning events into plain language

`events.jsonl` is Claude Code's `stream-json` output. The "Now" line and the
Details list come from these events:

| Event | Shown as |
|---|---|
| `system` / `init` | "Started" |
| `assistant` text block | Claude's message, as text |
| tool `Read`, `Grep`, `Glob` | "Looking at `<file>`" / "Searching the project" |
| tool `Edit`, `Write`, `NotebookEdit` | "Editing `<file>`" / "Creating `<file>`" |
| tool `Bash` | Its `description` input when present ("Run the tests"), else "Running a command" |
| tool `WebSearch`, `WebFetch` | "Looking things up online" |
| to-do tool (`TodoWrite`, or the newer task tools) | Updates the Plan checklist; not shown as a step. Headless Claude Code currently offers no to-do tool (seen on the dev VM, S1), so the Plan list stays empty for now; Claude writes its list as text instead |
| tool `Task` / `Agent` | "Working on a side task: `<description>`" |
| any other tool | "Using `<name>`" |
| `user` tool result with an error | Step marked with a small warning, detail in Details |
| `result` | Ends the turn: summary, cost, duration |

Tool names come from the harness and change between versions, so unknown ones
fall back to "Using `<name>`" instead of breaking. The mapping lives in the
Claude Code adapter (design section 6), not in the screens.

## 5. Notifications

Sent when a turn ends, to every device that turned them on (one household
user for now). Tapping opens the task page. A newer notification for the
same task replaces the older one.

| When | Title | Body |
|---|---|---|
| Finished | "Done: `<title>`" | First sentence of the summary |
| Needs your answer | "Claude has a question" | The question |
| Something went wrong | "Didn't finish: `<title>`" | "Tap to see what happened" |
| Interrupted | "Interrupted: `<title>`" | "The box restarted. Tap to continue" |

Nothing is sent for steps, for a task you stopped, or one taken out of line.

## 6. Flows

```
Home ──New task──> New task ──Start──> Task page (Getting ready → Working)
  ^                                        │
  │                          push "Done" ──┤
  │                                        v
  └──────── back ──────────────── Task page (Finished / Needs your answer)
                                    │                          │
                                  Reply                      Changes
                                    │
                         Task page (Waiting in line → Working)
```

- **Queue and walk away:** New task → Start → close the app → push → task page.
- **Answer a question:** push "Claude has a question" → task page with the
  question on top and the reply box focused → Send → Working.
- **Keep going after a stop or interruption:** task page → Reply ("keep going").
- **Wait your turn:** a task started while another works shows *Waiting in
  line* with its place, and starts by itself. **Take it out of line** stops
  it before it runs; a reply later starts it.
- **First run** (S5): open `http://clankstation.local` → **Connect to
  Tailscale** → sign in on Tailscale's site → (if asked) turn on HTTPS in the
  Tailscale admin console → **Open Clankstation** at `https://<name>.ts.net`
  → install it to the home screen → Settings → Set up Claude → Sign in → add
  a project → first task. Each device also needs the Tailscale app.

## 7. Not on day one

Multiple household accounts (one user, as in the OS phase), Windows tasks,
sending changes to GitHub as a pull request, choosing a branch or template per
task, task search, sharing a task, cost reports.

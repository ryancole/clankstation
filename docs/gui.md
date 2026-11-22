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
| Take over | Work with Claude yourself in a terminal | attach, PTY |
| Summary | Claude's own account of what it did | result event |

## 2. Task states as people see them

The box already knows these per task (`clankctl`'s `task_state` and
`status.json`). The GUI shows one label, one colour and one sentence.

| Box state | Label | Sentence on the task page | What you can do |
|---|---|---|---|
| `queued` (service layer, new) | Waiting in line | "It starts when another task finishes." | Cancel |
| `preparing` | Getting ready | "Setting up the project's tools. This can take a few minutes the first time." | Stop |
| `running` | Working | The current activity line (section 4) | Stop, Take over |
| `running`, mode `interactive` | You're in control | "Someone is working with Claude in a terminal." | Open terminal |
| `done`, summary ends with a question | Needs your answer | Claude's question, large | Reply |
| `done` | Finished | "Done. Here's what it did." | Reply, Take over |
| `failed` | Something went wrong | First line of the error in plain words, if known | Reply ("try again"), Take over |
| `stopped` | Stopped | "Stopped before it finished. Its work so far is kept." | Reply ("keep going"), Take over |
| `lost` | Interrupted | "The box restarted while this was working." | Reply ("keep going") |
| any, with `pruned` | Archived | "Its working files were cleaned up after 7 days. You can still read it." | Read only |

**Needs your answer** is the one state the box doesn't record today. In headless
mode Claude Code can't stop mid-turn to ask; it ends the turn, and its final
message is the question. First version: a finished turn whose summary's last
paragraph ends with `?` is shown as *Needs your answer*. Every finished task
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
  - Buttons: **Stop**, **Take over**.
- **When finished:**
  - **Summary:** `result/summary.md` rendered as formatted text.
  - **What changed:** "3 files changed" with each file name and a small
    added/removed bar (`result/diffstat.txt`). Tap a file to see its changes
    (3.4). "No files were changed" when the diff is empty.
  - **Reply box:** "Tell Claude what to do next" with a **Send** button.
    Sending starts a new turn in the same task (`clankctl resume`).
  - Buttons: **Take over**. Later: **Send to GitHub** (open a PR).
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

### 3.5 Take over (browser terminal)

- Before opening, if the task is working: "Claude is working on this right
  now. Taking over stops that and lets you continue the same conversation
  yourself." **Take over** / **Cancel**. (The same rule as `clankctl attach`:
  the harness is never driven by two things at once.)
- Then a full-screen terminal running `claude --resume <session-id>` in the
  task's environment: Claude Code's own interactive screen, unmodified.
- On a phone: an extra key row (Esc, Tab, Ctrl, arrows, Enter) above the
  keyboard.
- **Done, hand back** at the top ends the session. The page returns to the
  task, whose changes are refreshed.

### 3.6 Projects

A list of projects with the last task's date. **Add a project:** a name and
the git URL ("the address you'd use to clone it"). It runs `clankctl project
add`; a failed clone shows git's message under "Details".

### 3.7 Settings

- **Claude:** installed version and whether it's signed in (`claude auth
  status`). **Set up Claude** (installs it, `clankctl harness enable claude`)
  and **Sign in**, which opens a browser terminal running Claude's own sign-in
  (`claude auth login`). The app only carries keystrokes to and from that
  terminal. It never reads, logs or stores what passes through it.
- **Notifications:** on/off for this device, with a test button. On iPhone,
  a note that notifications need the app installed to the home screen first.
- **Install the app:** instructions for this browser (Add to Home Screen /
  Install).
- **The box:** current version, **Check for updates**, **Update now**
  (`clankctl update`), with a warning when a restart is needed for a new
  kernel. Free space on the data disk.

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
| to-do tool (`TodoWrite`, or the newer task tools) | Updates the Plan checklist; not shown as a step |
| tool `Task` / `Agent` | "Working on a side task: `<description>`" |
| any other tool | "Using `<name>`" |
| `user` tool result with an error | Step marked with a small warning, detail in Details |
| `result` | Ends the turn: summary, cost, duration |

Tool names come from the harness and change between versions, so unknown ones
fall back to "Using `<name>`" instead of breaking. The mapping lives in the
Claude Code adapter (design section 6), not in the screens.

## 5. Notifications

Sent when a turn ends, to every device of the task's user that turned them on.
Tapping opens the task page.

| When | Title | Body |
|---|---|---|
| Finished | "Done: `<title>`" | First sentence of the summary |
| Needs your answer | "Claude has a question" | The question |
| Something went wrong | "Didn't finish: `<title>`" | "Tap to see what happened" |
| Interrupted | "Interrupted: `<title>`" | "The box restarted. Tap to continue" |

Nothing is sent for steps, for a task you stopped, or for a take-over you
ended yourself.

## 6. Flows

```
Home ──New task──> New task ──Start──> Task page (Getting ready → Working)
  ^                                        │
  │                          push "Done" ──┤
  │                                        v
  └──────── back ──────────────── Task page (Finished / Needs your answer)
                                    │            │             │
                                  Reply      Take over     Changes
                                    │            │
                         Task page (Working)  Terminal ──Hand back──> Task page
```

- **Queue and walk away:** New task → Start → close the app → push → task page.
- **Answer a question:** push "Claude has a question" → task page with the
  question on top and the reply box focused → Send → Working.
- **Keep going after a stop or interruption:** task page → Reply ("keep going").
- **Take over:** task page → Take over → terminal → Hand back → task page.
- **First run** (after install, later): open `clankstation.local` → name
  yourself → Set up Claude → Sign in → add a project → first task.

## 7. Not on day one

Multiple household accounts (one user, as in the OS phase), Windows tasks,
sending changes to GitHub as a pull request, choosing a branch or template per
task, task search, sharing a task, cost reports.

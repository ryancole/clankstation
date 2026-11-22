# Clankstation design

Status: draft, OS layer done; service layer starting. Last updated 2026-11-21.

## 1. What Clankstation is

Clankstation is a slim NixOS-based OS for a dedicated, always-on computer on a
home network where AI coding agents do the work. It is a bouncer for agents:
you queue a prompt against a project, walk away, and come back to finished
work. Your own PC can be off the whole time. Code, toolchains, environments and
agent sessions all live on the Clankstation box.

Non-goals: Clankstation is **not** a security product. It is one trusted box on
a home LAN. No egress proxies, approval gates or credential brokers. Agents get
broad permissions inside their environment.

## 2. Principles

1. **OS first.** This phase builds the operating system: a reproducible NixOS
   image that can create task environments, run official agent harnesses in
   them, and keep their results. The web GUI, API, task queue and
   notifications are a *service layer* built on top later (section 8). Until
   then the OS is driven by a small admin CLI (`clankctl`).
2. **Latest stable releases of everything.** nixpkgs is pinned to the current
   stable NixOS release, and every other component uses its latest stable
   release. Bump when a new stable ships (NixOS 26.11 is due around the end of
   November 2026). No old versions kept for comfort.
3. **NixOS is the implementation, not the interface.** End users never edit
   `.nix` files. User-facing settings (projects, sign-ins, concurrency) end up
   as runtime state under `/var/lib/clankstation`, not in the system config.
   Nothing project-specific gets installed on the host.
4. **Official harnesses, unmodified.** See section 6.
5. **Small, verified increments.** Each milestone is checked in a VM before the
   next one starts.

## 3. Decisions

| Area | Decision | Status |
|---|---|---|
| Base OS | NixOS, flake, nixpkgs pinned to `nixos-26.05` (move to 26.11 when it is released) | Settled |
| Package versions | As shipped by the pinned stable nixpkgs (e.g. Docker 29.9, devcontainers CLI 0.87), even when upstream is newer; no overlays to newer versions | Settled (M6) |
| devcontainers | `devcontainer build` + agent layer; tasks run via Clankstation's own runner, not `devcontainer up` | Settled (M6) |
| Kernel | `linuxPackages_latest` (latest stable kernel, per principle 2). One line to revert to the default LTS kernel | Settled (by principle) |
| Linux environments | Docker (rootful, `virtualisation.docker`, Docker 29.x) | Settled |
| Windows environments | QEMU/KVM through libvirt, with a copy-on-write qcow2 overlay per task on a prepared base image | Settled (from brief) |
| Disk layout | ext4 root for NixOS; all Clankstation state on an XFS data partition or disk at `/var/lib/clankstation`; partitioned with disko (v1.13.0) | Settled, built in M1 |
| Source location | All source under `src/`; the repo root holds only top-level files | Settled |
| Default branch | `master` | Settled |
| Access | `clankstation.local` via Avahi/mDNS on the LAN. Not LAN-only: an owner may set the box up to be reached from anywhere. How (and which name and certificate) is the LAN HTTPS decision below | Changed 2026-11-21 (was LAN only) |
| Code to Windows VMs | git over the libvirt network, not a file share (section 5.6) | Proposed: confirm at M9 |
| Installer | Offline ISO with prebuilt systems + disko scripts for both layouts; disks chosen at install via fixed `/dev/clank-{boot,data}` links | Settled (M7) |
| Windows base images | Unattended install from the user's ISO via an answer-file CD; generic key (unactivated) unless one is given; Secure Boot off + check bypass; TPM 2.0 via swtpm; local `agent` account; host drives VMs over OpenSSH | Settled (M8) |
| First client | Installable web app (PWA) served by the box. For phone and PC alike, and for non-technical users. Day one: queue, status, result; push on done/needs input; reply/keep going; terminal take-over in the browser | Settled (2026-11-20) |
| Updates | Manual `clankctl update`: `nixos-rebuild switch --refresh --flake github:ryancole/clankstation/master?dir=src#<host>` (public repo, latest `master`). No update timer; the GUI triggers it later | Settled (M10) |
| Task retention | A daily timer removes a finished task's worktree (and overlay) 7 days after it finished; results and logs stay until `clankctl delete` | Settled (M10) |
| Web stack | Backend in Go (one static binary, `buildGoModule`; creack/pty for the terminal, a web push library, standard `net/http`). Frontend: a Svelte 5 single-page PWA built with Vite (`buildNpmPackage`), embedded in the binary; xterm.js for the browser terminal. Everything from the pinned nixpkgs, no new flake inputs. The service calls `clankctl` for task changes at first and reads the task files directly. Chosen over Rust mainly for build time and RAM: the box builds its own updates | Settled (2026-11-21) |
| API and event protocol | REST + JSON for actions. Server-Sent Events for live task events, with the event's sequence number as the SSE `id` so a reconnect resumes where it left off. One WebSocket per browser terminal. Raw harness output stays in `events.jsonl` as the record; the harness adapter (section 6) turns it into a small versioned Clankstation stream (`{v:1, seq, type: turn/message/step/step_result/plan/result/state, ...}`, where `seq` is the `events.jsonl` line number), and the GUI depends only on that | Settled (2026-11-21) |
| Sign-in from the browser | Settings' **Sign in** opens a browser terminal running Claude's own `claude auth login`. The one-time code the user pastes passes through `clank-web`'s WebSocket to Claude Code, relayed only: never logged, stored or read, as SSH relays it for `clankctl login claude` | Settled (2026-11-22) |
| Go dependencies | `clank-web` may use outside Go modules, pinned in `go.sum` (not flake inputs). First two, for the browser terminal (S3): `creack/pty` and `coder/websocket` | Settled (2026-11-22) |
| Queue and concurrency (S4) | The queue lives in `clankctl`, shared by the CLI and the web app: `run` and `resume` mark a task `queued` (a file in its task folder) when the box is at its limit, and a small systemd service starts the next one when a slot frees, so it keeps working while `clank-web` restarts. The limit is runtime state under `/var/lib/clankstation`, default 1. Nothing jumps the line or interrupts a run. **Take over is removed from the app for now** (the S3 terminal stays for Settings' install and sign-in; `clankctl attach` over SSH still works) | Settled (2026-11-22) |
| Login (S5) | Tailscale identity: the app is reachable only over Tailscale, and `clank-web` asks the local `tailscaled` who each connecting device belongs to (whois). Reaching the box on the tailnet, as Tailscale's own access rules allow, is the login; no Clankstation passwords | Settled (2026-11-22) |
| Joining Tailscale (S5) | A first-run page on `http://clankstation.local` (plain HTTP, setup only) shows Tailscale's own sign-in link; once the box has joined, it sends you to its `https://…ts.net` address. The box never handles Tailscale credentials | Settled (2026-11-22) |
| Where the app is served (S5) | HTTPS on the box's `*.ts.net` name only, at home and away. Plain HTTP on the LAN serves only the first-run page, or a link to the `ts.net` address | Settled (2026-11-22) |
| Push notifications (S6) | Web push with the box's own VAPID key pair, sent with `webpush-go` (Go module, pinned in `go.sum`). Keys, device subscriptions and the notifier's last-seen task states live in `settings/push/` on the data disk | Settled (2026-11-22) |
| HTTPS and remote access | Default: Tailscale (`services.tailscale` from nixpkgs, no new flake input). The app is served at the box's `*.ts.net` name with Tailscale's Let's Encrypt certificate, the same name at home and away (the PWA, service worker and push subscriptions are tied to one origin). The owner signs in to Tailscale through its own flow. Alternative, documented: the owner's own domain with an ACME DNS-01 certificate (`security.acme`), where the owner handles reachability (port forward, split DNS). LAN-only fallback: a box-local CA, name-constrained to the box, installed per device (also used on the dev VM). Not offered: tunnel services that terminate TLS (they would see the terminal during harness sign-in). Reachable from outside the home means the GUI always requires a household login | Settled (2026-11-21) |

## 4. Architecture

```
+-------------------------------------------------------------+
|  Service layer (later): web GUI, API, task queue, web push   |
+-------------------------------------------------------------+
|  clankctl (admin CLI, OS phase)                              |
+-------------------------------------------------------------+
|  Host OS (NixOS)                                             |
|   - project storage (bare git mirrors, worktrees)           |
|   - environment launchers: Docker, libvirt/QEMU             |
|   - per-user home volumes (harness installs + sign-in)      |
|   - mDNS, SSH, firewall, storage, cleanup timers            |
+-----------------------------+-------------------------------+
|  Linux task container       |  Windows task VM              |
|   worktree bind mount       |   qcow2 overlay on base image |
|   harness (claude) inside   |   harness (claude) inside     |
+-----------------------------+-------------------------------+
```

The harness always runs **inside** the environment, so the agent uses the real
toolchain (gcc/clang, MSVC, PowerShell) directly. The host only
launches environments, moves code in and out, and collects output.

## 5. OS components

### 5.1 Repository and flake layout

```
/                       repo root: top-level files only
  CLAUDE.md
  docs/design.md
  src/
    flake.nix           single flake for the whole project
    flake.lock
    hosts/
      clankstation/     the appliance configuration
      dev-vm/           build-vm overrides (test user, forwarded ports, fake data disk)
    modules/            NixOS modules, one per concern (storage, docker, libvirt, harness, ...)
    disko/              disk layouts
    images/
      linux-default/    default Linux task image (Dockerfile)
      windows/          unattended-install templates, post-install scripts
    pkgs/               clankctl and other local packages
    tests/              NixOS VM tests (run by `nix flake check`)
```

Flake inputs: `nixpkgs` (`nixos-26.05`) and `disko` (`v1.13.0`, its latest
release tag; follows our nixpkgs). Add others only when needed.

Flakes only see git-tracked files. New files must be `git add`ed (or
`git add -N`) before a build will see them.

### 5.2 Host configuration

- Hostname `clankstation`. Avahi publishes `clankstation.local`
  (`services.avahi.enable`, `nssmdns4`, `publish.enable`, `publish.addresses`).
- OpenSSH for administration and for `clankctl` in the OS phase.
- Firewall on. Only SSH and HTTP (port 80, the first-run page) are open on the
  LAN; the app's HTTPS port 443 is open on `tailscale0` only (S5). Docker and
  libvirt bridges are internal.
- Nix: flakes on, automatic store GC and optimisation on a timer.
- One admin login account in the OS phase. The household user account is part
  of the service layer.
- Updates (`src/modules/update.nix`): `clankctl update` rebuilds the box from
  the flake on GitHub (`clankstation.update.flake`, default
  `github:ryancole/clankstation/master?dir=src`), using the configuration it
  was installed as (`clankstation.update.configuration`, set per host in
  `flake.nix`; written to `/etc/clankstation/update.env`). It runs
  `nixos-rebuild switch --refresh`, so pins come from the repo's lock file.
  `--check` only compares the installed revision
  (`system.configurationRevision`, from the flake's git revision) with the
  latest. Manual only, never on a timer: running tasks survive the switch
  (Docker `live-restore`), and a new kernel waits for a reboot, which
  `clankctl update` points out. The dev VM has updates off; it's rebuilt from
  the repo in WSL. Later the GUI triggers updates.

### 5.3 Storage layout

Partitioning with disko (`src/modules/storage.nix`, options under
`clankstation.storage`):

- ESP (FAT32, 1 GiB, label `CLANK-ESP`) and root (ext4, label `clank-root`) on
  the boot disk (`bootDisk`).
- Data: XFS (label `clank-data`, `noatime`), mounted at `/var/lib/clankstation`.
  It is a second disk when `dataDisk` is set, which is the recommended setup
  (root then fills the boot disk). Otherwise it is the rest of the boot disk,
  after a 64 GiB root (`rootSize`).
- Filesystems mount by GPT partition label, so disk device paths only matter
  when the installer formats the disks. XFS is chosen for reflinks:
  copying base images and large SDKs is close to free. Docker's
  overlay2 driver needs `ftype=1`, which is the mkfs.xfs default.

Directory tree, created with `systemd.tmpfiles`:

```
/var/lib/clankstation/
  projects/<project>/
    mirror.git                bare mirror of the remote; source for every task clone
    project.env               url=, template=
  tasks/<task-id>/            task id: t-YYYYMMDD-HHMMSS-xxxx
    task.env                  project, branch, base, created, user
    prompt.txt, base, resume  inputs for the in-container runner (current turn)
    prompts.log               every turn: run / resume / attach, with its prompt
    worktree/                 the task's own local clone, on branch clank/<task-id>
    events.jsonl, stderr.log  raw harness stream-json events and stderr (all turns)
    status.json               state (done/failed/stopped), mode, exit code, session id, times
    queued                    while waiting in line: the time it joined (S4)
    image, devcontainer.json  devcontainer tasks: image tag, merged metadata
    prepare.log, lifecycle.log  devcontainer build and lifecycle command output
    result/                   summary.md, diff.patch, diffstat.txt
  users/<user>/
    home/                     per-user home volume, mounted as /home/agent in every
                              environment (harness installs, sign-in, caches)
  docker/                     Docker data-root
  vm/
    base/<name>.qcow2         prepared Windows base images (read-only), + .json, .password
    build/<name>/             base image builds: answer CD, disk, serial.log, screen.png
    iso/                      user-supplied Windows ISOs
    overlays/<task-id>.qcow2  per-task copy-on-write overlays
    tools/<name>.qcow2        optional shared toolchain disks (large SDKs), overlaid per task
  tasks/.queue.lock           held while the queue checks for a free slot and starts a task
  settings/box.env            box settings set at runtime (max_running=, default 1)
  settings/push/              web push (S6): vapid.json (the box's key pair, 0600),
                              subscriptions.json (one per device), seen.json
                              (each task's last state, so restarts don't repeat
                              or miss a notification)
  cache/                      shared build caches (later)
```

Cleanup (`src/modules/cleanup.nix`): the `clankstation-clean` timer runs
`clankctl clean --older-than 7d` daily as the service user
(`clankstation.cleanup.retention`, `.dates`). For each task that is done,
failed or stopped and finished longer ago than that, it removes the worktree
and any `vm/overlays/<task-id>.qcow2`, and writes the time to `pruned`. Such a
task keeps its prompt, events, logs and `result/` (show and diff still work),
but can't be resumed, attached or shelled into. Running, preparing and lost
tasks are never touched. It also removes devcontainer images
(`clankstation/dc-*`, with their `-base`) built before the cutoff that no task
with a worktree uses; the next task of that project rebuilds its image.
Docker `autoPrune` (weekly) removes dangling images and stopped containers.
Nothing under `vm/base/` or `vm/tools/` is removed automatically.
`clankctl delete <task-id>` removes a task entirely.

Cloud installs (AWS, Azure) use the same split: a boot disk and an attached
data disk, with cloud snapshots for backup. Windows task VMs need KVM inside the
instance: on Azure, many sizes support nested virtualization; on AWS, use
bare-metal instances or the newer types that allow nested virtualization.

### 5.4 Linux environments (Docker)

- `virtualisation.docker.enable` (`src/modules/docker.nix`), with the package
  left at the default (`docker_29`), overlay2, and `data-root` at
  `/var/lib/clankstation/docker` on the data disk. `live-restore` (the
  default) keeps task containers running while dockerd restarts. Container
  logs are rotated, and a weekly prune removes stopped containers and dangling
  images.
- **Service user:** the host user `clankstation` (uid/gid 2000, in the `docker`
  group) owns `projects/`, `tasks/`, `users/` and `cache/`. In containers the
  `agent` user has the same uid/gid, so bind-mounted worktrees have one owner
  on both sides.
- **Default image** (`src/images/linux-default/Dockerfile`): `FROM ubuntu:26.04`
  (the latest Ubuntu LTS; the floating tag picks up point releases), with git,
  build-essential, python3, curl, ripgrep, tmux and similar, plus `agent` with
  passwordless sudo. No harness is baked in. A systemd timer
  (`clankstation-image-linux-default`, 30 s after boot, then daily) builds it
  when it's missing, tagged by a hash of the Dockerfile and uid/gid plus
  `:latest`, so a changed Dockerfile gets rebuilt. It needs network access,
  so it retries every minute until it succeeds and never holds up boot.
- **devcontainer.json** (M6): with the project template `auto` (the default),
  a repo with `.devcontainer/devcontainer.json` or `.devcontainer.json` runs in
  its own devcontainer. `--template linux-default` opts out.
  - **Build:** `devcontainer build` (devcontainers CLI from nixpkgs) builds the
    image, features included. An agent layer (`src/images/devcontainer-agent`)
    then remaps the config's `remoteUser` to uid/gid 2000, the same idea as the
    CLI's `updateRemoteUserUID`. If `remoteUser` is root or unset, it adds an
    `agent` user instead. The image is tagged `clankstation/dc-<project>:<hash>`,
    where the hash covers the devcontainer files and the agent layer, so it is
    reused until those change.
  - **Prepare step:** the build runs in the background after `clankctl run`
    returns (state `preparing`, log in `prepare.log`), then the task starts.
  - **Running:** tasks don't use `devcontainer up`. They keep Clankstation's
    model of one `--rm` container per turn, running the runner. The merged
    image metadata (`devcontainer.metadata` label) gives `remoteUser`,
    `containerEnv` (passed as `--env`) and the lifecycle hooks. The runner runs
    `onCreate`/`updateContent`/`postCreate` once per task and `postStart` on
    every turn, logging to `lifecycle.log`. A failure is logged and the task
    carries on, like an editor does.
  - **Not supported yet:** docker compose configs (refused with a message),
    `runArgs`, `mounts`, `capAdd`/`privileged`, `forwardPorts`, `remoteEnv`,
    `${...}` values in `containerEnv`, and non-default config paths
    (`.devcontainer/<name>/devcontainer.json`). The workspace is always
    `/workspace`, not `/workspaces/<repo>`. The image hash doesn't see build
    context files outside `.devcontainer/`.
- Mounts per task: the task worktree at `/workspace`, and the user's home
  volume at `/home/agent` (5.7).
- One container per task, removed when the task ends. The worktree and results
  stay on the host.

### 5.5 Windows environments (libvirt)

- **libvirt** (`src/modules/libvirt.nix`, M8): QEMU 10.2 and libvirt 12.2,
  with `qemu.swtpm.enable` for the TPM 2.0 that Windows 11 needs.
  - **Firmware:** UEFI comes from QEMU's bundled edk2 (`<os firmware='efi'>`)
    with Secure Boot off; setup's Secure Boot check is bypassed instead.
  - **QEMU:** runs as root with `dynamic_ownership = 0`, so images and logs
    keep their `clankstation` owner.
  - **Network:** VMs use the NAT network `clank` (bridge `clankbr0`,
    192.168.250.0/24, host .1), defined at boot by a oneshot unit. Docker gets
    `ip-forward-no-drop`; otherwise its FORWARD DROP policy also drops the
    VMs' traffic.
  - **Later:** virtiofsd would go in via `qemu.vhostUserPackages`.
- **Base image provisioning**, unattended:
  `clankctl windows build-base <name> --iso <file>`. Files are in
  `src/images/windows/`.
  1. **Answer-file CD:** the user copies a Windows ISO into `vm/iso/`.
     clankctl writes a CD (`genisoimage`) with `Autounattend.xml`,
     `setup.ps1`, `config.json`, the virtio `viostor`/`vioscsi`/`NetKVM`
     drivers and `virtio-win-guest-tools.exe` (virtio-win from nixpkgs).
  2. **Answer file:** it selects the edition by name (default
     "Windows 11 Pro"). With no `--key`, it uses Microsoft's public generic
     install key, which installs unactivated. It bypasses the TPM, Secure
     Boot, RAM and CPU checks, and turns off automatic device encryption (each
     task VM gets a fresh TPM). It creates a local `agent` administrator with
     a generated password (kept in `vm/base/<name>.password`, for the console
     only) and one autologon to run `setup.ps1`.
  3. **The install VM:** a transient libvirt domain (`build-domain.xml`):
     q35, a virtio disk and NIC, the Windows ISO and answer CD on SATA, a
     TPM 2.0 emulator, Hyper-V enlightenments, COM1 to `serial.log`, and VNC
     on localhost. A background process presses Enter for the DVD's "press
     any key" prompt, waits for power-off (4 h limit) and saves a screenshot
     every 20 s (`clankctl windows screenshot`).
  4. **`setup.ps1`:** installs the virtio guest tools, OpenSSH server (with
     PowerShell 7 as its shell), the latest PowerShell 7 and Git for Windows
     (GitHub releases), and the latest VS Build Tools C++ workload
     (`aka.ms/vs/stable`, unless `--no-build-tools`, then checked by finding
     `cl.exe`). It sets long paths, a high-performance power plan, no
     hibernation, no automatic update reboots and Defender exclusions for
     build directories. It turns autologon off, logs to COM1, and powers off
     after `CLANK-SETUP-DONE` or `CLANK-SETUP-FAILED`.
  5. **Finalize:** on `DONE`, the disk becomes `vm/base/<name>.qcow2`
     (read-only) with `vm/base/<name>.json`.
  - A template can add more tools later (for example .NET SDKs or a game
    engine), optionally on a separate toolchain disk so several templates
    can share one large install.
- **Data disk growth:** `clankstation-grow-data` grows the data partition and
  its XFS filesystem to fill the disk on every boot (`growpart` +
  `xfs_growfs`), for enlarged virtual and cloud disks.
- **Per task**: a qcow2 overlay on the base image, plus an overlay on each
  toolchain disk the template uses. The VM gets a unique hostname at first
  boot. The overlays are deleted when the task is cleaned up.
- No GPU by default. Builds, tests and command-line tooling don't need one.
  GPU passthrough is an advanced option, later.

### 5.6 Getting code into and out of environments

- **Linux containers:** each task gets a local `git clone` of the project
  mirror. Objects are hardlinked, so it's cheap on the same filesystem, and
  `origin` is set back to the real upstream URL. It's checked out on branch
  `clank/<task-id>` and bind-mounted at `/workspace`. A clone rather than a
  `git worktree`, because a worktree's `.git` file points at an absolute host
  path that doesn't exist inside the container, and because a clone keeps the
  agent away from the mirror. The diff (against the base commit, untracked
  files included, using a temporary index so the agent's own index is left
  alone) is written at the end of the task.
- **Windows VMs (proposed):** git over the libvirt network. The host serves the
  project mirror (read-only smart HTTP, or `git daemon` on the libvirt bridge
  only). The VM clones the task branch onto its own NTFS disk, and pushes the
  result branch back when the task finishes. Why not a share: MSBuild and other
  Windows build tools are slow over SMB/virtiofs, and file watchers and long paths
  break. Small, low-I/O data (harness config) does use virtiofs.

### 5.7 Harness integration

Hard rules (from the brief, non-negotiable):

- Run official vendor harnesses unmodified: Claude Code first, then Codex CLI and
  Gemini CLI behind the same adapter interface.
- Never patch or reimplement a harness. Never disable its built-in auth methods.
  Never use `--bare` (it cannot use subscription logins).
- Clankstation never collects, stores, proxies or reads subscription
  credentials or session tokens. The user signs in through the vendor's own flow
  (`claude` then `/login`). The harness keeps its own token.
- Each user brings their own subscription or API key.
- Harnesses are opt-in and are not preinstalled in the base system.

How this works for Claude Code:

- **Per-user home volume** `users/<user>/home/` (owned by `clankstation`, mode
  0700) is mounted as `/home/agent` in every Linux environment, so the user
  signs in once, not once per task. Clankstation mounts the directory and
  never reads its contents. It is a whole home directory, not just a
  `CLAUDE_CONFIG_DIR`, because the native installer and its auto-updater
  spread files across `~/.local/{bin,share,state}`, `~/.cache` and `~/.claude`
  and move files between them. Separate bind mounts would break those moves
  (a rename across mount points fails). Shared caches and dotfiles across a
  user's tasks are an accepted side effect.
- **Install:** `clankctl harness enable claude` runs the official native
  installer (`https://claude.ai/install.sh`) inside a container, into the home
  volume. That gives the latest release, and Claude Code's own auto-update
  keeps it there. Sign-in: `clankctl login claude` runs `claude auth login`
  (the vendor's flow) in a container. `clankctl harness status` shows
  `claude auth status`.
- **Windows VMs** need their own design here (M9). One home volume can't be
  shared with Windows as-is, so the likely shape is a native install in the
  base image plus a per-user config directory over virtiofs.
- **Headless run:** `claude -p "<prompt>" --output-format stream-json --verbose
  --permission-mode bypassPermissions`, as the non-root `agent` user (the
  environment is the sandbox). A small runner script
  (`src/pkgs/clankctl/task-run.sh`, mounted read-only into the container) runs
  the harness, then writes the summary (the final `result` event), the session
  id (the `init` event), the diff and `status.json`. It is the first, shell-only
  form of the per-environment worker. Events go to `tasks/<id>/events.jsonl`.
  The runner's own tools (bash, coreutils, git, jq) come from the host's
  `/nix/store`, bind-mounted read-only, so it works in any image. The harness
  and lifecycle commands run with the image's own `PATH`, with
  `/home/agent/.local/bin` in front.
- **Keep going / answer a question:** `clankctl resume <task> "<reply>"` starts
  a new headless turn with `--resume <session-id>` on the same worktree. Events
  are appended, the summary is that turn's result, and the diff stays
  cumulative against the original base. Every turn's prompt goes to
  `prompts.log`. A lost task (the box went down mid-turn, so no
  `status.json`) continues from the session named in its events.
- **Watch:** `clankctl logs [-f]` renders the event stream (assistant text,
  tool calls, results). `clankctl shell --task` opens a shell in the running
  container, or in a fresh one on the worktree.
- **Stop:** `clankctl stop` runs `docker stop` (containers use `--init` and a
  30 s stop timeout). The runner passes SIGTERM to the harness and still writes
  the diff and a `stopped` status, so a stopped task can be resumed.
- **Take over:** `clankctl attach` runs `claude --resume <session-id>`
  interactively in a new container on the task's worktree, in your terminal.
  A running headless turn is stopped first, after a confirmation prompt or
  `--yes`. The harness is never driven by two processes at once. On exit the
  diff is refreshed and the task is handed back (`mode: interactive` in
  `status.json`). Windows VMs will use a ConPTY session over SSH (M9).

### 5.8 clankctl (OS-phase admin CLI)

A small command-line tool on the host that exercises the OS before the service
layer exists, and that the service layer can replace or wrap later. It is
written as a shell application (`writeShellApplication`) so it doesn't commit
us to a language before the web stack decision.

```
clankctl project add [--template auto|linux-default] <name> <git-url>   # Windows templates: M9
clankctl project list
clankctl harness enable claude          # opt-in install into the user's home volume
clankctl harness status                 # installed version + `claude auth status`
clankctl login claude                   # vendor sign-in (`claude auth login`)
clankctl shell [cmd...]                 # shell in the default image with the home volume
clankctl run <project> "<prompt>"       # create task, start env, run headless
clankctl status                         # all tasks: running / done / failed / stopped / lost
clankctl show <task-id>                 # prompt, state, session, summary, diffstat
clankctl diff <task-id>
clankctl logs <task-id> [-f]            # what the agent did; -f follows a running task
clankctl resume <task-id> "<prompt>"    # keep going in the same session
clankctl attach [--yes] <task-id>       # take over interactively
clankctl stop <task-id>
clankctl shell --task <task-id> [cmd]   # shell in the task's environment
clankctl clean [--older-than 7d] [--dry-run]   # also run daily by a timer
clankctl delete <task-id>               # remove a task, results included
clankctl queue                          # tasks waiting in line
clankctl config [set max-running <n>]   # how many tasks run at once (default 1)
clankctl update [--check]               # rebuild the box from GitHub
```

Task containers are started detached (`docker run --detach --rm`), so dockerd
owns them. They keep going after the SSH session that started them
disconnects, and `live-restore` keeps them running through dockerd restarts.
`run` and `resume` go through the queue (S4): when the box already runs
`max_running` tasks, the task waits in line (`clankctl queue`) and the
`clankstation-queue` service starts it when a slot frees up. `stop` on a
waiting task takes it out of line; a reply to it later starts it with its
first prompt and the reply. `attach` over SSH doesn't wait in line (it is
the admin's way in), but a take-over in progress fills a slot.

### 5.9 Installation

- An installer ISO built from the flake (`nix build ./src#installer-iso`;
  `src/installer/`): a minimal NixOS live system on the latest kernel, UEFI
  only. `sudo clankstation-install` does the rest:
  1. Lists the disks and asks for the OS disk and an optional data disk.
  2. Asks for an SSH public key for `admin`, or a console password if none is
     given.
  3. Asks you to type `ERASE`, then partitions, formats and installs.
  4. Reboots.
- **Fully offline:** the ISO carries both appliance variants (`clankstation`
  for two disks, `clankstation-one-disk`) as prebuilt systems, with their disko
  destroy-format-mount scripts. Their layouts target fixed paths
  (`/dev/clank-boot`, `/dev/clank-data`), and the installer symlinks the chosen
  disks there, so nothing is evaluated or built at install time.
  `nixos-install --system` copies the closure from the ISO's store.
- **SSH key:** written to `~admin/.ssh/authorized_keys`. `admin` has a fixed
  uid 1000, so this works before first boot. SSH stays key-only.
- **Boot entries:** systemd-boot writes an NVRAM boot entry and also installs
  the removable fallback (`EFI/BOOT/BOOTX64.EFI`), so a disk moved to another
  machine still boots.
- After the service layer exists, the user finishes setup in the web GUI on
  `clankstation.local`.
- Cloud images (AWS, Azure) come later from the same configuration through the
  NixOS image builders.

### 5.10 Testing

- Development happens on Windows 11 with Nix in the `NixOS` WSL distro, which
  has KVM.
- The `dev-vm` host for manual checks (`system.build.devVm`, a wrapper around
  disko's VM variant). It boots from disks formatted with the real layout
  (16 GiB boot disk, 20 GiB data disk). The root disk is fresh on every run.
  The data disk persists in `~/.local/share/clankstation-dev/` in WSL, so
  sign-ins, projects, tasks and Docker images survive rebuilds (`--reset`
  wipes it).
- NixOS VM tests in `src/tests/` for automated checks, run by `nix flake check`.
  `m0-boot` covers SSH and mDNS between two nodes. `m1-storage-*` uses disko's
  test helper to format blank disks, install the system, boot it, and check
  both layouts. `m2-docker` checks the Docker data-root on XFS and a
  uid-matched worktree bind mount. VM tests have no network, so it uses a
  digest-pinned `ubuntu:26.04` (`src/images/linux-default/base-image.nix`),
  and the full image build is checked in the dev VM. `m7-installer` runs
  `clankstation-install` in a UEFI VM onto two blank disks, boots them on a
  fresh UEFI machine with no boot entries, and logs in over SSH with the
  installed key. `m8-windows-plumbing` covers everything around a Windows
  build except Windows itself: libvirt, swtpm, the `clank` network, Docker's
  forward policy, data-disk growth, and a dry-run `build-base` (valid answer
  file, answer CD contents, a domain libvirt accepts and boots to firmware).
  The real Windows install runs on the box. `m10-cleanup-update` runs the
  cleanup timer's service against old, recent and running tasks and
  devcontainer images, checks that a cleaned task keeps its results, and
  checks `clankctl update` against stub `nix` and `nixos-rebuild` (no
  network). A real update is checked on an installed box.
- Windows VM milestones need real hardware, or libvirt running directly in WSL.
  Windows inside build-vm inside WSL is too many layers of nesting to be usable.
  A Hyper-V Gen 2 VM with nested virtualization works as a stand-in box:
  Secure Boot off, static memory, DVD first in the boot order. The appliance
  and ISO load `hv_storvsc` early in boot for its disks.

## 6. Harness adapter (for later harnesses)

Each harness adapter defines how to: install it (official installer, into the
user's volume), mount its config directory, start a headless run, resume a
session, start an interactive session, and parse its event stream into the
common task states (queued, running, needs input, done, failed). Claude Code is
the only adapter in the OS phase. The interface is written down once there is a
second harness to fit it to.

## 7. Milestones (OS phase)

Each milestone ends with a check in the VM.

| # | Milestone | Done when |
|---|---|---|
| M0 | Flake skeleton in `src/`, pinned nixpkgs, host config, `dev-vm` | build-vm boots; SSH works; `clankstation.local` resolves from the LAN side |
| M1 | Storage: disko layout, data tree, tmpfiles | In the VM, the data disk is XFS at `/var/lib/clankstation` with the expected tree |
| M2 | Docker plus the default Linux image | `docker run` of the default image works with a worktree bind mount |
| M3 | Home volume: opt-in Claude Code install and one-time sign-in | After `/login` once, a fresh container is already signed in |
| M4 | First end-to-end task via `clankctl run` | A prompt runs headless in a container, survives SSH disconnect, and leaves a summary and a diff |
| M5 | Take over and resume: `clankctl attach`, `clankctl resume` | Can attach to a running task, and continue a finished one |
| M6 | devcontainer.json support | A repo with a devcontainer gets its own environment |
| M7 | Installer ISO (moved up from M9 so the Windows milestones can run on real hardware) | The ISO installs offline in a VM test, and on the real box: it boots and takes SSH with the installed key. Done: also installed on a Hyper-V Gen 2 VM (two disks, nested virtualization, `/dev/kvm` present) |
| M8 | libvirt and unattended Windows base image | A base image builds from a user ISO with no clicks (real hardware). Done: Windows 11 Pro + VS 2026 Build Tools built unattended on the Hyper-V box |
| M9 | Windows tasks: overlays, git sync, harness. **Shelved** (2026-11-21) until the box's RAM/storage upgrade; first step when resumed: a Windows Server 2025 Core base image that just boots and takes SSH | M4's check passes against a Windows template |
| M10 | Cleanup timers and updates | Old tasks and overlays get pruned; the box updates from this repo. Done: cleanup in `m10-cleanup-update`; on a fresh Hyper-V install from the ISO, `clankctl update --check` matched GitHub and the box updated itself from GitHub to the commit that recorded this |

M4 is the brief's first milestone ("send a prompt and come back to a finished
diff"), driven from the CLI instead of the browser.

## 8. Service layer

Covers: the web GUI for non-technical users, the API, the task queue and
concurrency limits, the worker service inside each environment with a
versioned event protocol, the monitoring view, web push notifications,
plain-language result pages with actions (open PR, keep going), and the
browser terminal. Stack, protocol and HTTPS are in the decisions table.

The GUI's screens, flows and plain-language wording are in `docs/gui.md`.

`clank-web` (`src/pkgs/clank-web`, module `src/modules/web.nix`): Go,
standard library only, with the Svelte app (`ui/`) built by
`buildNpmPackage` and embedded. It runs as `clankstation`, reads the task
files and asks the Docker socket which task containers are running. Every
change (new task, reply, stop, add project) runs `clankctl` as the same
user, with prompts on stdin; clankctl stays the one writer of the data
tree. API v1 and the event envelope are documented at the top of `api.go`
and `adapter.go`. Actions only accept same-origin JSON POSTs, so other web
pages can't drive the box; that is not a login (S5). Browser terminals
(`terminal.go`) run `clankctl login claude` or `clankctl harness enable
claude` under a PTY and relay it over a WebSocket. A session outlives the
page (a phone that sleeps reconnects and gets the screen back); one nobody
has looked at for 10 minutes is ended. Taking over a task was built in S3
and taken out of the app in S4 (decisions table): nothing interrupts a run
or skips the line.
Settings reads Claude's state from `clankctl harness status` and passes on
only installed, version, signed in, method and plan (not the account's email
or organization).

Tailscale (S5, `tailscale.go`, `setup.go`; module `src/modules/web.nix`,
enabled on the appliance): `services.tailscale` runs on the box with
`permitCertUid` set to the service user (so `clank-web` can fetch the
ts.net certificate) and `--operator=clankstation` (so it can start
Tailscale's sign-in). `clank-web` talks to tailscaled's LocalAPI on its Unix
socket (standard library only): `status`, `whois`, `cert/<name>`,
`login-interactive` and `prefs`. Listeners:

- `-https :443`: the app, with the ts.net certificate (kept until two weeks
  before it expires). It is fetched in the background with a 5-minute
  limit: the first one has Tailscale set a DNS record for Let's Encrypt,
  which took 34 s on the dev VM, and the first-run page says it's on its
  way meanwhile. Every request is checked with `whois`; a device
  Tailscale can't name gets a "This device can't use Clankstation" page.
  `GET /api/me` returns the Tailscale login, name and device.
- `-setup :80`: the first-run page at `http://clankstation.local`: **Connect
  to Tailscale** (only while the box isn't connected) shows Tailscale's own
  sign-in link, then asks to turn on HTTPS certificates in the Tailscale
  admin console if needed, then links to `https://<name>.ts.net`. A device
  already on the tailnet is redirected there.
- `-listen`: the app over plain HTTP with no login, dev VM only
  (`clankstation.web.devListen`): `http://localhost:8080` in WSL and
  Windows; the first-run page is forwarded to `http://localhost:8081`. The
  dev VM keeps Tailscale's state on its data disk, so it stays on its tailnet
  across runs.

The app is installable (web app manifest, icons, a service worker that
caches nothing). Pages use `Referrer-Policy: same-origin`:
under `no-referrer` browsers send `Origin: null` on form posts, which the
cross-site check refuses.

Notifications (S6, `push.go`): web push with the box's own VAPID key pair,
sent with `webpush-go` (encryption RFC 8291, VAPID RFC 8292; the "sub"
claim is the box's https address). A device turns them on in Settings; its
browser's push subscription is stored with the Tailscale login and device
it came from. A notifier checks the task list every 3 s and sends one
notification when a turn ends (docs/gui.md section 5), to every device:
done, needs an answer, failed, or interrupted by a restart; nothing for a
stopped task. Each task's last state is kept in `seen.json`, so a restart
neither repeats a notification nor misses a task the restart interrupted.
The payload is `{title, body, url, tag}`; the service worker shows it, and
tapping opens the task. A device whose subscription is gone (404/410) is
forgotten.

### 8.1 Milestones (service layer)

Each is verified on the dev VM (and a NixOS VM test where it fits).

| # | Milestone | Done when |
|---|---|---|
| S1 | Read-only service: Go binary serving the embedded Svelte app, NixOS module, systemd unit as `clankstation`. Home, task page, Changes; live events over SSE through the Claude Code adapter. Enabled on the dev VM only until S5 adds login | A task started with `clankctl run` shows up in a browser on the dev VM and updates live while it works. Done: `s1-web` VM test (API, SSE resume, needs-input, changes); on the dev VM a real Claude Code task showed live steps, then its question, summary and diff, and the page reconnected after the service restarted |
| S2 | Actions: new task, reply, stop, projects (through `clankctl`) | A task can be queued and continued from the browser alone. Done: `s2-actions` VM test (add project, new task, answer, stop and keep going, continue a lost task, cross-site refusal); on the dev VM a real Claude Code task was started from New task, asked its question, and finished after a reply sent from the task page |
| S3 | Browser terminal: take over (WebSocket + PTY), Claude install and sign-in from Settings | Take over and hand back work from the browser. Done: `s3-terminal` VM test (take over a working task, leave and reconnect, hand back with the diff refreshed, sign-in code not in the service's log, Claude status without the email); on the dev VM, real Claude Code was taken over mid-task from the browser, given an instruction, and handed back with its file in the changes |
| S4 | Queue and concurrency limit (`queued` state); take-over out of the app | With a limit of 1, a second task waits, then starts on its own. Done: `s4-queue` VM test (line order, take out of line and start later, replies wait, CLI and web share one line, a limit of 2 runs two) and the full `nix flake check`; on the dev VM two real Claude Code tasks were queued and the second started by itself when the first finished |
| S5 | Login, Tailscale, HTTPS, installable PWA | Installed on a phone, reachable away from home, login required. So far: `s5-tailnet` VM test (real tailscaled on the box and a "phone" with Headscale: first-run page before and after joining, the phone gets in as its Tailscale user, the box's own loopback and a LAN device are refused); on the dev VM (2026-11-22), the real flow: first-run page, Tailscale sign-in, HTTPS enabled in the admin console, a Let's Encrypt certificate for its ts.net name, and the app opened and installed on a phone over Tailscale. Done (2026-11-22): on the Hyper-V box after `clankctl update`, the box joined the tailnet from the first-run page, and the app on a phone opened over Tailscale on Wi-Fi and on mobile data; Claude signed in and the phone terminal's Paste worked |
| S6 | Web push | The phone gets "Done" and "Claude has a question". So far: `s6-push` VM test (a stand-in push service that decrypts what the box sends like a phone would: the test button, "Done", "Claude has a question", a reply that finishes, nothing for a stopped task), Go tests that decrypt the payload (RFC 8291). On the box (2026-11-22): turned on from the home-screen app on an iPhone, and the test notification arrived (a Sleep Focus had hidden it at first). Still to check: a task's "Done" or "Claude has a question" on the phone |
| S7 | Box settings: updates, storage | "Update now" works from the GUI |

## 9. Open questions

- Code transfer to Windows VMs: confirm git sync at M9.
- Windows licensing: base images install unactivated with the generic key
  unless `--key` is given. Decide how activation works for task VMs cloned
  from one base (activation per clone vs. never activating).
- The first Windows build attempt once restarted out of setup before copying
  any files (cause unknown; the retry worked). If it recurs, the build's
  screenshots will show the error.
- How harness install and sign-in work in Windows VMs (5.7), given that the
  Linux home volume can't simply be shared.
- Upgrade disko when a release newer than v1.13.0 ships. That release should
  have the test-driver fix (then drop the `machine.shutdown()` workaround in
  `src/tests/m1-storage.nix`) and the changes needed for NixOS 26.11.
- Later: macOS workers, a separate Windows PC as a worker, multiple users.

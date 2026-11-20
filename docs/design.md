# Clankstation design

Status: draft, OS layer. Last updated 2026-11-20.

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
| Kernel | `linuxPackages_latest` (latest stable kernel, per principle 2). One line to revert to the default LTS kernel | Settled (by principle) |
| Linux environments | Docker (rootful, `virtualisation.docker`, Docker 29.x) | Settled |
| Windows environments | QEMU/KVM through libvirt, with a copy-on-write qcow2 overlay per task on a prepared base image | Settled (from brief) |
| Disk layout | ext4 root for NixOS; all Clankstation state on an XFS data partition or disk at `/var/lib/clankstation`; partitioned with disko (v1.13.0) | Settled, built in M1 |
| Source location | All source under `src/`; the repo root holds only top-level files | Settled |
| Default branch | `master` | Settled |
| Access | LAN only, `clankstation.local` via Avahi/mDNS. Tailscale optional later | Settled (from brief) |
| Code to Windows VMs | git over the libvirt network, not a file share (section 5.6) | Proposed: confirm at M8 |
| Web stack, event protocol | Deferred to the service layer (section 8) | Open |

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
|   - per-user harness volumes                                |
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
- Firewall on. Only SSH (and later the GUI port) is open on the LAN. Docker and
  libvirt bridges are internal.
- Nix: flakes on, automatic store GC and optimisation on a timer.
- One admin login account in the OS phase. The household user account is part
  of the service layer.
- Updates: `nixos-rebuild switch --flake` from this repo's lock file. Later the
  GUI triggers updates.

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
    mirror.git                bare clone of the remote; source for all worktrees
  tasks/<task-id>/
    worktree/                 git worktree (Linux tasks)
    events.jsonl              raw harness event stream
    result/                   final summary, diff, metadata
  users/<user>/
    claude/                   harness volume: CLAUDE_CONFIG_DIR + native install
  docker/                     Docker data-root
  vm/
    base/<template>.qcow2     prepared Windows base images (read-only once built)
    overlays/<task-id>.qcow2  per-task copy-on-write overlays
    tools/<name>.qcow2        optional shared toolchain disks (large SDKs), overlaid per task
    iso/                      user-supplied Windows ISO, virtio-win drivers
  cache/                      shared build caches (later)
```

Cleanup: a systemd timer prunes finished tasks' worktrees and overlays after a
retention period, runs `docker system prune` for unused images (Docker
`autoPrune`), and never touches `base/` or `tools/` automatically. Results
(`events.jsonl`, `result/`) are kept until the task is deleted.

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
- **devcontainer.json**: when a repo has one, build and start the environment
  with the devcontainers CLI (latest release), then add Clankstation's mounts.
- Mounts per task: the task worktree at `/workspace`, and the user's harness
  volume (5.7).
- One container per task, removed when the task ends. The worktree and results
  stay on the host.

### 5.5 Windows environments (libvirt)

- `virtualisation.libvirtd.enable` (QEMU 10.2, libvirt 12.2), with
  `qemu.swtpm.enable` for the TPM 2.0 that Windows 11 needs. OVMF/Secure Boot
  firmware ships with QEMU by default in this release (the old
  `qemu.ovmf` submodule is removed). virtiofsd goes in via
  `qemu.vhostUserPackages`.
- **Base image provisioning**, unattended:
  1. The user supplies a Windows ISO and, optionally, a product key.
  2. The host generates an `autounattend.xml` on a small attached image and
     attaches the latest stable virtio-win driver ISO.
  3. Post-install scripts install the toolchain: latest Visual Studio Build
     Tools, Git, PowerShell 7, OpenSSH server. A template can add more
     (for example .NET SDKs or a game engine), optionally on a separate
     toolchain disk so several templates can share one large install.
  4. The VM shuts down. The disk becomes a read-only base image.
- **Per task**: a qcow2 overlay on the base image, plus an overlay on each
  toolchain disk the template uses. The VM gets a unique hostname at first
  boot. The overlays are deleted when the task is cleaned up.
- No GPU by default. Builds, tests and command-line tooling don't need one.
  GPU passthrough is an advanced option, later.

### 5.6 Getting code into and out of environments

- **Linux containers:** bind-mount the task worktree. The diff is computed on
  the host.
- **Windows VMs (proposed):** git over the libvirt network. The host serves the
  project mirror (read-only smart HTTP, or `git daemon` on the libvirt bridge
  only). The VM clones the task branch onto its own NTFS disk, and pushes the
  result branch back when the task finishes. Why not a share: MSBuild and other
  Windows build tools are slow over SMB/virtiofs, and file watchers and long paths
  break. Small, low-I/O data (the harness volume) does use virtiofs.

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

- **Per-user harness volume** `users/<user>/claude/` is mounted into every
  environment, with `CLAUDE_CONFIG_DIR` pointing at it, so the user signs in
  once, not once per task. Clankstation mounts the directory and never reads
  its contents.
- **Install:** opting in runs the official native installer into the volume.
  That gives the latest release, and Claude Code's own auto-update keeps it
  there. Windows VMs reach the volume over virtiofs. If that turns out to be
  unreliable for running the binary, the base image gets a native install and
  only the config directory is shared.
- **Headless run:** `claude -p "<prompt>" --output-format stream-json --verbose`
  with permissions bypassed inside the environment (the environment is the
  sandbox). Events go to `tasks/<id>/events.jsonl`.
- **Keep going / answer a question:** a new headless run with
  `--resume <session-id>` in the same environment and worktree.
- **Take over:** start `claude --resume <session-id>` interactively in a
  terminal inside the environment (tmux in containers, a ConPTY session over SSH
  in Windows VMs).

### 5.8 clankctl (OS-phase admin CLI)

A small command-line tool on the host that exercises the OS before the service
layer exists, and that the service layer can replace or wrap later. It is
written as a shell application (`writeShellApplication`) so it doesn't commit
us to a language before the web stack decision.

```
clankctl project add <name> <git-url> [--template linux-default|<windows-template>]
clankctl harness enable claude          # opt-in install into the user's volume
clankctl login claude                   # interactive shell to run /login
clankctl run <project> "<prompt>"       # create task, start env, run headless
clankctl status [<task-id>]
clankctl attach <task-id>               # live terminal in the task environment
clankctl diff <task-id>
clankctl resume <task-id> "<prompt>"
clankctl clean [--older-than 7d]
```

Tasks run as systemd transient units (`systemd-run`), so they keep going after
the SSH session that started them disconnects.

### 5.9 Installation

- A custom installer ISO built from the flake. It boots, asks which disk(s) to
  use, runs disko and `nixos-install` with the Clankstation configuration, and
  reboots. After the service layer exists, the user finishes setup in the web
  GUI on `clankstation.local`.
- Cloud images (AWS, Azure) come later from the same configuration through the
  NixOS image builders.

### 5.10 Testing

- Development happens on Windows 11 with Nix in the `NixOS` WSL distro, which
  has KVM.
- The `dev-vm` host for manual checks, built as disko's `vmWithDisko`. It boots
  from fresh disk images formatted with the real layout (16 GiB boot disk,
  20 GiB data disk).
- NixOS VM tests in `src/tests/` for automated checks, run by `nix flake check`.
  `m0-boot` covers SSH and mDNS between two nodes. `m1-storage-*` uses disko's
  test helper to format blank disks, install the system, boot it, and check
  both layouts. `m2-docker` checks the Docker data-root on XFS and a
  uid-matched worktree bind mount. VM tests have no network, so it uses a
  digest-pinned `ubuntu:26.04` (`src/images/linux-default/base-image.nix`),
  and the full image build is checked in the dev VM.
- Windows VM milestones need real hardware, or libvirt running directly in WSL.
  Windows inside build-vm inside WSL is too many layers of nesting to be usable.

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
| M3 | Harness volume: opt-in Claude Code install and one-time sign-in | After `/login` once, a fresh container is already signed in |
| M4 | First end-to-end task via `clankctl run` | A prompt runs headless in a container, survives SSH disconnect, and leaves a summary and a diff |
| M5 | Take over and resume: `clankctl attach`, `clankctl resume` | Can attach to a running task, and continue a finished one |
| M6 | devcontainer.json support | A repo with a devcontainer gets its own environment |
| M7 | libvirt and unattended Windows base image | A base image builds from a user ISO with no clicks (real hardware) |
| M8 | Windows tasks: overlays, git sync, harness over virtiofs | M4's check passes against a Windows template |
| M9 | Cleanup timers and installer ISO | Fresh install from the ISO on a spare machine or VM; old tasks get pruned |

M4 is the brief's first milestone ("send a prompt and come back to a finished
diff"), driven from the CLI instead of the browser.

## 8. Service layer (later)

Built on the OS once M4 or so is solid. Covers: the web GUI for non-technical
users, the API, the task queue and concurrency limits, the worker service inside
each environment with a versioned event protocol, the monitoring view, web push
notifications, plain-language result pages with actions (open PR, keep going),
and the browser terminal. Decisions needed then: web stack, event protocol
format, how needs-input tasks are shown and answered.

## 9. Open questions

- Web stack and event protocol (service layer).
- Code transfer to Windows VMs: confirm git sync at M8.
- Windows licensing: how an unactivated or evaluation install is handled when
  no key is given.
- Whether running the Claude Code binary from a virtiofs share works well on
  Windows, or whether it needs a native install in the base image.
- Retention defaults for finished tasks and overlays.
- Upgrade disko when a release newer than v1.13.0 ships. That release should
  have the test-driver fix (then drop the `machine.shutdown()` workaround in
  `src/tests/m1-storage.nix`) and the changes needed for NixOS 26.11.
- Later: macOS workers, a separate Windows PC as a worker, multiple users,
  Tailscale.

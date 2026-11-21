# Clankstation

A slim NixOS-based OS for an always-on home box where AI coding agents run
tasks unattended. Read `docs/design.md` before making changes. It holds the
architecture, the decisions table and the milestones.

## Current phase: OS first

Build the operating system layer (flake, host config, storage, Docker, libvirt,
harness volumes, `clankctl`, installer). Do not start the web GUI, API, task
queue or event protocol until the OS milestones are done and the user picks the
web stack.

## Repo layout

- The repo root holds only top-level files: `CLAUDE.md`, `docs/`, `.gitignore`,
  and similar.
- All source lives under `src/`: `src/flake.nix`, `hosts/`, `modules/`,
  `disko/`, `images/`, `pkgs/`, `tests/`. See design section 5.1.
- Default branch is `master`. Never rename it.

## Versions

- Use the latest stable release of everything. nixpkgs is pinned to the current
  stable NixOS branch (`nixos-26.05`; move to `nixos-26.11` once it is released).
  Other inputs and tools use their latest stable release, never an older one
  without a stated reason.
- Check every NixOS option name and package attribute against the **pinned**
  nixpkgs, not memory. For example, fetch the locked source and grep it:
  `nix flake prefetch github:NixOS/nixpkgs/<rev> --json` gives a store path,
  then grep `<store>/nixos/modules/...`.

## Hard rules for agent harnesses

- Run official vendor harnesses (Claude Code first) unmodified. Never patch,
  reimplement or wrap their agent loop. Never disable their built-in auth.
- Never use `claude --bare`.
- Clankstation never collects, stores, proxies or reads subscription
  credentials or session tokens. Users sign in through the vendor's own flow.
  The harness config directory is a per-user volume that is mounted, never read.
- Harnesses are opt-in and are never preinstalled in the base system.
- Nothing project-specific gets installed on the host. Project toolchains live
  in task environments.

## Not a security product

One trusted box on a home LAN. Do not add egress proxies, approval gates or
credential brokers. Agents get broad permissions inside their environment.

## Building and testing

Development is on Windows 11. Nix runs in the WSL distro `NixOS`, which has KVM.
That distro has no `git` on its PATH, and Nix needs it for a flake inside a git
repo, so wrap commands in `nix shell ...#git`. From the repo root in WSL
(`/mnt/c/Users/Ryan/Documents/code/clankstation`):

```
export NIX_CONFIG="experimental-features = nix-command flakes"
nix shell nixpkgs/nixos-26.05#git -c nix flake check ./src      # eval + VM tests
nix shell nixpkgs/nixos-26.05#git -c nix build ./src#nixosConfigurations.dev-vm.config.system.build.devVm
./result/bin/clank-dev-vm                                         # --reset wipes the persistent data disk
ssh -p 2222 admin@localhost                                       # dev VM only: password admin
```

- The dev VM boots from disko-formatted disks, not plain `build-vm`. The disko
  layout mounts the data disk by partition label, and plain `build-vm` has no
  such disk, so boot would hang waiting for it. Its data disk
  (`~/.local/share/clankstation-dev/data.qcow2` in WSL) persists across runs:
  the user's Claude sign-in lives there. Don't `--reset` it without asking.
- disko-based VM tests (`src/tests/m1-storage.nix`) must end with
  `machine.shutdown()`, or the build hangs after the test passes.

- Flakes only see git-tracked files. `git add` (or `git add -N`) new files
  before building.
- Verify each step in the VM (build-vm or a NixOS VM test) before moving on, and
  say what was verified and how.
- Windows VM work needs real hardware or libvirt directly in WSL, not build-vm.

## Working with the user

- Work in small increments, one milestone at a time.
- Ask before choosing anything hard to reverse: web stack, event protocol,
  environment runtime, storage layout, new flake inputs. Record each decision in
  the decisions table in `docs/design.md`.
- Keep `docs/design.md` current when a design choice changes.

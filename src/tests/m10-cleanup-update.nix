# M10: old tasks get pruned, and the box updates from this repo.
#
# Cleanup: a finished task older than the retention period loses its worktree
# (results stay), recent and running tasks are left alone, unused devcontainer
# images go, and `clankctl delete` removes a task entirely.
#
# Updates: VM tests have no network, so stub `nix` and `nixos-rebuild` stand
# in for GitHub and the rebuild. The test checks what clankctl asks for (the
# box's own configuration, from the configured flake). A real update is
# checked on an installed box.
{ self, pkgs }:
let
  testImage = pkgs.dockerTools.buildLayeredImage {
    name = "clankstation/linux-default";
    tag = "latest";
    contents = with pkgs; [
      bashInteractive
      coreutils
      findutils
      git
      gnugrep
      gnused
      jq
      dockerTools.binSh
      dockerTools.usrBinEnv
    ];
    extraCommands = "mkdir -m 1777 tmp";
  };

  stubClaude = pkgs.writeText "claude-stub" ''
    #!/bin/sh
    prompt="$2"
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    case "$prompt" in *slow*) sleep 600 ;; esac
    echo "$prompt" >> NOTES.md
    # Agents can leave read-only files and directories behind.
    mkdir -p ro && echo x > ro/f && chmod -R a-w ro
    echo '{"type":"result","subtype":"success","is_error":false,"result":"Noted.","session_id":"stub-session-1"}'
  '';

  # Stand-ins for GitHub and the rebuild.
  stubNix = pkgs.writeShellScript "nix" ''
    echo "$*" >> /tmp/stub/calls
    echo '{"revision":"rev-2"}'
  '';
  stubNixCurrent = pkgs.writeShellScript "nix" ''
    echo "$*" >> /tmp/stub/calls
    echo '{"revision":"rev-1"}'
  '';
  stubRebuild =pkgs.writeShellScript "nixos-rebuild" ''
    echo "nixos-rebuild $*" >> /tmp/stub/calls
  '';
in
pkgs.testers.runNixOSTest {
  name = "m10-cleanup-update";

  nodes.clankstation =
    { lib, ... }:
    {
      imports = [
        self.nixosModules.default
        ../hosts/clankstation
      ];
      disko.enableConfig = false;
      virtualisation.memorySize = 2048;
      systemd.timers.clankstation-image-linux-default.enable = lib.mkForce false;
      clankstation.update.configuration = "clankstation";
      system.configurationRevision = "rev-1";
    };

  testScript = ''
    tasks = "/var/lib/clankstation/tasks"

    clankstation.wait_for_unit("docker.service")
    clankstation.succeed("docker load < ${testImage}")

    # --- The cleanup timer is installed ---------------------------------------
    clankstation.succeed("systemctl is-active clankstation-clean.timer")
    assert "--older-than 7d" in clankstation.succeed("systemctl cat clankstation-clean.service")

    # --- Some tasks -----------------------------------------------------------
    clankstation.succeed(
        "mkdir -p /srv/upstream",
        "cd /srv/upstream && git init -q -b main && echo '# Demo' > README.md"
        " && git add README.md && git -c user.name=t -c user.email=t@example.com commit -qm init",
        "chown -R clankstation:clankstation /srv/upstream",
        "clankctl project add demo /srv/upstream",
        "clankctl shell sh -c 'mkdir -p ~/.local/bin && cat > ~/.local/bin/claude"
        " && chmod +x ~/.local/bin/claude' < ${stubClaude}",
    )

    def run(prompt):
        out = clankstation.succeed(f"su admin -c \"clankctl run demo '{prompt}'\" 2>/dev/null")
        return out.strip().splitlines()[0]

    def wait_done(task):
        clankstation.wait_until_succeeds(f"test -f {tasks}/{task}/status.json", timeout=120)

    old = run("old task")
    recent = run("recent task")
    wait_done(old)
    wait_done(recent)
    running = run("slow task")
    clankstation.wait_until_succeeds(f"clankctl status | grep -E '{running}\\s+running'")

    # The old task finished ten days ago.
    clankstation.succeed(
        f"cd {tasks}/{old} && ${pkgs.jq}/bin/jq '.finished = \"'$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)'\"' status.json > s"
        " && mv s status.json && chown clankstation:clankstation status.json"
    )
    # The recent task uses a devcontainer image; another one is unused.
    clankstation.succeed(
        "docker tag clankstation/linux-default:latest clankstation/dc-demo:used",
        "docker tag clankstation/linux-default:latest clankstation/dc-demo:unused",
        "docker tag clankstation/linux-default:latest clankstation/dc-demo:unused-base",
        f"echo clankstation/dc-demo:used > {tasks}/{recent}/image",
    )

    # --- Dry run changes nothing ----------------------------------------------
    out = clankstation.succeed("su admin -c 'clankctl clean --dry-run'")
    assert f"would clean {old}" in out, out
    assert recent not in out and running not in out, out
    assert "would remove image clankstation/dc-demo:unused" in out, out
    assert "dc-demo:used\n" not in out, out
    clankstation.succeed(f"test -d {tasks}/{old}/worktree")
    clankstation.fail("su admin -c 'clankctl clean --older-than soon' 2>&1")

    # --- The timer's service prunes the old task only -------------------------
    clankstation.succeed("systemctl start clankstation-clean.service")
    clankstation.fail(f"test -e {tasks}/{old}/worktree")
    clankstation.succeed(f"test -s {tasks}/{old}/pruned")
    clankstation.succeed(f"test -d {tasks}/{recent}/worktree")
    clankstation.succeed(f"test -d {tasks}/{running}/worktree")
    images = clankstation.succeed("docker image ls --format '{{.Repository}}:{{.Tag}}'")
    assert "clankstation/dc-demo:used" in images, images
    assert "dc-demo:unused" not in images, images
    assert "clankstation/linux-default:latest" in images, images

    # Results stay; the task can't continue.
    show = clankstation.succeed(f"clankctl show {old}")
    assert "Cleaned:" in show and "Noted." in show, show
    assert "+old task" in clankstation.succeed(f"clankctl diff {old}")
    out = clankstation.fail(f"clankctl resume {old} 'more' 2>&1")
    assert "cleaned up" in out, out
    out = clankstation.fail(f"clankctl attach --yes {old} 2>&1")
    assert "cleaned up" in out, out
    out = clankstation.fail(f"clankctl shell --task {old} true 2>&1")
    assert "cleaned up" in out, out

    # A second run has nothing left to do.
    assert "Cleaned 0 task(s)." in clankstation.succeed("clankctl clean")

    # --- delete ---------------------------------------------------------------
    out = clankstation.fail(f"clankctl delete {running} 2>&1")
    assert "is running" in out, out
    clankstation.succeed(f"clankctl delete {old}")
    clankstation.fail(f"test -e {tasks}/{old}")
    assert old not in clankstation.succeed("clankctl status")
    clankstation.succeed(f"clankctl stop {running}")

    # --- update ---------------------------------------------------------------
    clankstation.succeed(
        "mkdir -p /tmp/stub && ln -s ${stubNix} /tmp/stub/nix && ln -s ${stubRebuild} /tmp/stub/nixos-rebuild"
        " && chmod 0777 /tmp/stub"
    )
    stub = "PATH=/tmp/stub:$PATH"

    # --check (as admin): shows both revisions, rebuilds nothing.
    out = clankstation.succeed(f"su admin -c '{stub} clankctl update --check'")
    assert "Installed: rev-1 (clankstation)" in out, out
    assert "Latest:    rev-2 (github:ryancole/clankstation/master?dir=src)" in out, out
    clankstation.fail("grep nixos-rebuild /tmp/stub/calls")

    # update: rebuilds this box's configuration from the flake.
    clankstation.succeed(f"{stub} clankctl update")
    calls = clankstation.succeed("cat /tmp/stub/calls")
    assert "flake metadata --refresh --json github:ryancole/clankstation/master?dir=src" in calls, calls
    assert "nixos-rebuild switch --refresh --flake github:ryancole/clankstation/master?dir=src#clankstation" in calls, calls

    # Already at the latest revision: nothing to do.
    clankstation.succeed("rm /tmp/stub/calls && ln -sf ${stubNixCurrent} /tmp/stub/nix")
    out = clankstation.succeed(f"{stub} clankctl update")
    assert "Up to date." in out, out
    clankstation.fail("grep nixos-rebuild /tmp/stub/calls")
  '';
}
